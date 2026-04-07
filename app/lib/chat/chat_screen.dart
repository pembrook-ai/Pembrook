/// ChatScreen — the main Pembrook conversation UI.
///
/// Sends messages to @agent via RpcService.call() and renders the response.
/// Subscribes to RpcService.streamChunkEvents for incremental token rendering
/// (streaming mode from the agent). Chunks are filtered by conversationId so
/// only the screen that sent the request renders its own response.
///
/// Multi-device sync:
///   All @owner devices receive the same atPlatform stream notifications.
///   When the agent signals 'done: true' on a stream chunk for a conversation
///   this device did NOT initiate, the screen reloads ConversationStore from
///   the remote AtKey so the completed exchange appears in history on all devices.
///   When the app resumes from background (AppLifecycleState.resumed) the store
///   is also reloaded from the remote atServer.
///
/// Multi-session chat:
///   Each chat session has a unique [_conversationId] (UUIDv4).
///   Tapping the "New conversation" button (➕) saves the current session to
///   [ConversationStore] and starts a fresh UUID.
///   Past sessions can be browsed from the History screen and reloaded here.
///
/// Navigation drawer:
///   Home (chat), History, Audit Log, Skills, HITL Approvals, Settings.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/data_service.dart';
import '../services/rpc_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Internal message model
// ─────────────────────────────────────────────────────────────────────────────

class _Message {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  _Message({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

// ─────────────────────────────────────────────────────────────────────────────
//  Chat action menu
// ─────────────────────────────────────────────────────────────────────────────

enum _ChatAction { clearNotifications, deleteChat }

// ─────────────────────────────────────────────────────────────────────────────
//  ChatScreen
// ─────────────────────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final List<_Message> _messages = [];
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final Uuid _uuid = const Uuid();
  late String _conversationId;

  // Cached reference so we can safely call it from dispose().
  ConversationStore? _store;
  RpcService? _rpcService;

  bool _isLoading = false;
  String _streamBuffer = '';
  String _progressMessage = ''; // Current progress message (e.g., "🌐 Fetching content...")
  // Mirrors the 'streamingEnabled' SharedPreferences setting.
  // Re-read at the start of every _send() so changes in Settings take effect
  // on the next message without requiring a restart.
  bool _streamingEnabled = true;
  // Explicitly tracks which conversationId is currently streaming.
  // Set just before rpcService.call(), cleared when the response arrives.
  // NOT cleared on conversation switch — stays alive so backgrounded responses
  // can still be routed correctly.
  String? _activeStreamConvId;
  // Stream chunk buffers for in-flight requests whose conversation is not
  // currently displayed (user switched away mid-flight).
  final Map<String, String> _bgStreamBuffers = {};
  // Tracks conversation IDs where THIS device called _send().
  // Used in _convCompletedSub to distinguish the originator (let _send() handle
  // the response) from a passive viewer (loaded this conv from history on another
  // device — must finalise the streaming buffer itself).
  final Set<String> _originatedConvIds = {};
  StreamSubscription<StreamChunkEvent>? _streamSub;
  StreamSubscription<PushMessage>? _pushSub;
  // Fires when another device completes a conversation; triggers history reload.
  StreamSubscription<String>? _convCompletedSub;
  // Watchdog: if done:true is dropped on the network while Device B is passively
  // watching a remote stream, this timer fires after 15 s of chunk inactivity
  // and force-finalises the streaming buffer so the spinner never hangs.
  Timer? _remoteStreamWatchdog;
  // Set to the conversationId of a remote stream we are passively watching.
  // Cleared when that stream finalises (done:true or watchdog).
  // Used to:
  //   (a) trigger the question-load on the FIRST notification (progress or content)
  //       so the question appears before any progress/answer text.
  //   (b) gate progress display so late/stale notifications arriving after
  //       finalisation never flash the progress indicator on a completed chat.
  String? _remoteStreamingConvId;

  static const String _welcomeText = 'Hello! I\'m your Pembrook AI assistant. All our communication is '
      'end-to-end encrypted via the atPlatform. How can I help you today?';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _conversationId = _uuid.v4();
    _messages.add(_Message(text: _welcomeText, isUser: false));
    // Capture the store reference after the first frame so context is available.
    // Do NOT call load() here — ConversationStore is a long-lived provider that
    // is already populated by initialise() and stays correct across route changes.
    // A load() here would race with any in-flight _persist() write and overwrite
    // freshly-saved conversations with stale remote data on every nav-back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _store = context.read<ConversationStore>();
    });
    // Read streaming pref so the initial state mirrors Settings.
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) {
        setState(() {
          _streamingEnabled = prefs.getBool('streamingEnabled') ?? true;
        });
      }
    });
  }

  /// Reload conversation history from the remote AtKey when the app is foregrounded.
  /// This handles "picked up a second device" — history is always fresh from the server.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store?.load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = context.read<ConversationStore>();
    _rpcService = context.read<RpcService>();
    _streamSub?.cancel();
    // Filter stream chunks to only this conversation's chunks.
    // Because _conversationId is read at event-fire time (not captured),
    // this correctly handles conversation switches without re-subscribing.
    _streamSub = _rpcService!.streamChunkEvents.listen((event) {
      if (!_streamingEnabled) return;
      final isOurRequest = event.conversationId == _activeStreamConvId;
      // Accept chunks for the currently displayed conversation from any device
      // (same conv, different device — isRemoteOnCurrentConv).
      // Also buffer chunks for any OTHER conversation arriving while we are
      // idle (_activeStreamConvId == null) — they will be shown/discarded
      // once the completion signal arrives and we know what to do with them.
      final isRemoteOnCurrentConv = event.conversationId == _conversationId && _activeStreamConvId == null;
      final isOtherRemoteConv = event.conversationId != _conversationId && _activeStreamConvId == null;
      if (!isOurRequest && !isRemoteOnCurrentConv && !isOtherRemoteConv) return;

      // ── First event for a remote conversation we're passively viewing ──────
      // Fires on the first notification (progress OR content), so the question
      // is fetched from the AtKey before any progress text or answer tokens
      // appear in the UI.  Device A writes the question to the AtKey at the
      // very start of _send(), so by the time the first stream notification
      // arrives the write has had time to propagate.
      if (isRemoteOnCurrentConv && _remoteStreamingConvId != event.conversationId) {
        _remoteStreamingConvId = event.conversationId;
        final capturedConvId = _conversationId;
        Future.delayed(const Duration(milliseconds: 800), () async {
          if (!mounted || _conversationId != capturedConvId) return;
          await _store?.load();
          if (!mounted) return;
          final summary = _store?.get(capturedConvId);
          if (summary != null && summary.messages.length > _messages.length) {
            setState(() {
              _messages
                ..clear()
                ..addAll(summary.messages.map((s) => _Message(
                      text: s.text,
                      isUser: s.isUser,
                      timestamp: s.timestamp,
                    )));
            });
          }
        });
      }

      if (event.type == 'progress') {
        // Show progress only for an actively in-flight stream:
        //   • own request   → _activeStreamConvId matches  (_isLoading is true)
        //   • passive viewer → _remoteStreamingConvId matches
        // Late / stale notifications arriving after finalisation are discarded
        // (_remoteStreamingConvId is null once the stream completes).
        final showForOwn = isOurRequest && event.conversationId == _conversationId;
        final showForRemote = isRemoteOnCurrentConv && _remoteStreamingConvId == event.conversationId;
        if (showForOwn || showForRemote) {
          setState(() => _progressMessage = event.chunk);
          _scrollToBottom();
        }
      } else {
        // Content chunks: append to stream buffer
        if (event.conversationId == _conversationId) {
          // Arm (or reset) the watchdog on every remote content chunk so that
          // if done:true is dropped by the network the spinner still clears
          // after 15 s of inactivity.
          if (isRemoteOnCurrentConv) {
            final watchdogConvId = event.conversationId;
            _remoteStreamWatchdog?.cancel();
            _remoteStreamWatchdog = Timer(const Duration(seconds: 15), () async {
              if (!mounted || _streamBuffer.isEmpty) return;
              // done:true was lost — finalise now using the same logic as the
              // passive-viewer branch of _convCompletedSub.
              final answer = _streamBuffer.trim();
              _remoteStreamingConvId = null; // mark stream as no longer active
              // Keep _streamBuffer alive during the load so there is no gap.

              await _store?.load();
              if (!mounted) return;
              var summary = _store?.get(watchdogConvId);
              if (!_isConversationComplete(summary)) {
                await Future.delayed(const Duration(seconds: 2));
                if (!mounted) return;
                await _store?.load();
                if (!mounted) return;
                summary = _store?.get(watchdogConvId);
              }
              if (_isConversationComplete(summary)) {
                setState(() {
                  _streamBuffer = '';
                  _progressMessage = '';
                  _messages
                    ..clear()
                    ..addAll(summary!.messages.map((s) => _Message(
                          text: s.text,
                          isUser: s.isUser,
                          timestamp: s.timestamp,
                        )));
                });
              } else if (answer.isNotEmpty) {
                final currentMsgs = List<_Message>.from(_messages);
                setState(() {
                  _streamBuffer = '';
                  _progressMessage = '';
                  _messages
                    ..clear()
                    ..addAll(currentMsgs)
                    ..add(_Message(
                      text: answer,
                      isUser: false,
                      timestamp: DateTime.now(),
                    ));
                });
                _saveCurrentConversation();
              } else {
                setState(() {
                  _streamBuffer = '';
                  _progressMessage = '';
                });
              }
              _scrollToBottom();
            });
          }
          setState(() => _streamBuffer += event.chunk);
          _scrollToBottom();
        } else {
          // Buffer chunk for a backgrounded or unknown remote conversation.
          _bgStreamBuffers[event.conversationId] = (_bgStreamBuffers[event.conversationId] ?? '') + event.chunk;
        }
      }
    });
    // Reload conversation history when any conversation completes anywhere.
    // All @owner devices receive the same stream notifications from @agent.
    _convCompletedSub?.cancel();
    _convCompletedSub = _rpcService!.conversationCompletedEvents.listen((convId) {
      Future.delayed(const Duration(seconds: 3), () async {
        if (!mounted) return;

        if (convId == _conversationId) {
          if (_originatedConvIds.contains(convId)) {
            // ── Originating device ────────────────────────────────────────
            // This device called _send() for this conversation.  _send() will
            // receive the RPC reply, add the response to _messages, and call
            // _saveCurrentConversation().  Loading from remote here would race
            // with the in-flight _persist() write and overwrite fresh in-memory
            // state with stale data — making the conversation vanish.
            return;
          }

          // ── Passive viewer ────────────────────────────────────────────────
          // This device is watching a remote conversation complete.
          // _streamBuffer has the streamed *answer* chunks (via isRemoteOnCurrentConv
          // in _streamSub) but NOT the user's question — question text is only
          // ever in _messages on the originating device, never in stream notifications.
          //
          // Load the full conversation from the remote AtKey (written by the
          // originating device ~2 s after done: true, so by the time this
          // 3 s delayed callback fires it should be available).
          _remoteStreamWatchdog?.cancel(); // done:true arrived — watchdog not needed
          _remoteStreamingConvId = null; // stream no longer active — stop stale progress
          final streamedAnswer = _streamBuffer.trim(); // capture before clear
          // Do NOT clear _streamBuffer yet — keep the streaming bubble visible
          // during the async load so the answer never blinks out.

          await _store?.load();
          if (!mounted) return;

          var updated = _store?.get(convId);
          // Retry if the remote AtKey is missing or only has the question-only
          // snapshot (Device A writes the question immediately at the start of
          // _send(); the answer write follows ~2 s later after the RPC returns).
          if (!_isConversationComplete(updated)) {
            await Future.delayed(const Duration(seconds: 2));
            if (!mounted) return;
            await _store?.load();
            if (!mounted) return;
            updated = _store?.get(convId);
          }

          if (_isConversationComplete(updated)) {
            // Remote has full conversation — swap streaming bubble → proper
            // messages in a single setState so there is no blank frame.
            setState(() {
              _streamBuffer = '';
              _progressMessage = '';
              _messages
                ..clear()
                ..addAll(updated!.messages.map((s) => _Message(
                      text: s.text,
                      isUser: s.isUser,
                      timestamp: s.timestamp,
                    )));
            });
            _scrollToBottom();
          } else if (streamedAnswer.isNotEmpty) {
            // Remote only has the question snapshot (or is unavailable).
            // Build from current _messages (has the question from the 800ms
            // load, including the welcome) + the streamed answer — atomic swap.
            final currentMsgs = List<_Message>.from(_messages);
            setState(() {
              _streamBuffer = '';
              _progressMessage = '';
              _messages
                ..clear()
                ..addAll(currentMsgs)
                ..add(_Message(
                  text: streamedAnswer,
                  isUser: false,
                  timestamp: DateTime.now(),
                ));
            });
            _saveCurrentConversation();
            _scrollToBottom();
          } else {
            // Streaming disabled and remote unavailable — just clear the buffer.
            setState(() {
              _streamBuffer = '';
              _progressMessage = '';
            });
          }
          return;
        }

        // ── Remote device ─────────────────────────────────────────────────
        // A different conversation (Device B's UUID ≠ this device's current
        // UUID) completed.  Load from remote to get question + answer.
        //
        // Capture the buffered stream chunks BEFORE removing them — we may
        // need them as a fallback if the remote AtKey only has the
        // question-only snapshot (Device A writes question at the start of
        // _send() and answer ~2 s later; T+3 s may still be too early).
        final bufferedAnswer = (_bgStreamBuffers.remove(convId) ?? '').trim();

        await _store?.load();
        if (!mounted) return;

        // Retry until the conversation is complete (has an agent reply after
        // the question).  A question-only snapshot is not sufficient.
        var _remoteConv = _store?.get(convId);
        if (!_isConversationComplete(_remoteConv)) {
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          await _store?.load();
          if (!mounted) return;
          _remoteConv = _store?.get(convId);
        }

        final hasUserMessages = _messages.any((m) => m.isUser);
        if (!hasUserMessages) {
          // This device is idle (just the welcome message).
          if (_isConversationComplete(_remoteConv)) {
            // Remote has full conversation — auto-switch.
            setState(() {
              _streamBuffer = '';
              _conversationId = _remoteConv!.id;
              _messages
                ..clear()
                ..addAll(_remoteConv.messages.map((s) => _Message(
                      text: s.text,
                      isUser: s.isUser,
                      timestamp: s.timestamp,
                    )));
            });
            _scrollToBottom();
          } else if (_remoteConv != null && bufferedAnswer.isNotEmpty) {
            // Remote has question only; append the buffered streamed answer.
            setState(() {
              _streamBuffer = '';
              _conversationId = _remoteConv!.id;
              _messages
                ..clear()
                ..addAll(_remoteConv.messages.map((s) => _Message(
                      text: s.text,
                      isUser: s.isUser,
                      timestamp: s.timestamp,
                    )))
                ..add(_Message(
                  text: bufferedAnswer,
                  isUser: false,
                  timestamp: DateTime.now(),
                ));
            });
            _saveCurrentConversation();
            _scrollToBottom();
          }
          // else: no data at all — nothing to show.
        }
        // else: another device completed while this one has an active chat —
        // silently updated in history, accessible via the History screen.
      });
    });
    // Subscribe to proactive push messages from scheduled tasks.
    // listenToPushMessages() also drains any messages that arrived while
    // this screen was unmounted (e.g. user was on Settings/Skills screen).
    _pushSub?.cancel();
    _pushSub = _rpcService!.listenToPushMessages(_conversationId, (push) {
      // Only show in this chat if the push belongs to the current conversation
      // (or has no routing). Otherwise the badge is already updated.
      if (push.conversationId.isNotEmpty && push.conversationId != _conversationId) {
        // Persist the push to its originating conversation so History shows
        // a highlighted, tappable tile even when this screen is not active.
        _store?.appendPushMessage(
          push.conversationId,
          '⏰ ${push.description}',
          StoredMessage(
            text: '**\u23f0 ${push.description}**\n\n${push.result}',
            isUser: false,
            timestamp: push.ts,
          ),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _messages.add(_Message(
          text: '**\u23f0 ${push.description}**\n\n${push.result}',
          isUser: false,
          timestamp: push.ts,
        ));
      });
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Persist the current conversation before the screen disposes.
    _saveCurrentConversation();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _streamSub?.cancel();
    _convCompletedSub?.cancel();
    _remoteStreamWatchdog?.cancel();
    // Release before cancel so RpcService re-enables buffering immediately.
    _rpcService?.releasePushListener();
    _pushSub?.cancel();
    super.dispose();
  }

  // ──────────────────────────────────────────────────────────
  //  CONVERSATION PERSISTENCE
  // ──────────────────────────────────────────────────────────

  /// Save current session to ConversationStore.
  /// Skips if there are no user messages.
  void _saveCurrentConversation() {
    if (_store == null) return;
    if (_messages.every((m) => !m.isUser)) return; // nothing to save

    final userMessages = _messages.where((m) => m.isUser).toList();
    final title =
        userMessages.first.text.length > 80 ? '${userMessages.first.text.substring(0, 77)}…' : userMessages.first.text;

    _store!.save(ConversationSummary(
      id: _conversationId,
      title: title,
      createdAt: _messages.first.timestamp,
      messages: _messages
          .map((m) => StoredMessage(
                text: m.text,
                isUser: m.isUser,
                timestamp: m.timestamp,
              ))
          .toList(),
    ));
  }

  /// Load a past conversation from [summary].
  void _loadConversation(ConversationSummary summary) {
    // Mark this conversation as read and drain any pending push messages.
    _rpcService?.markConvRead(summary.id);
    final pendingPushes = _rpcService?.drainPushesForConv(summary.id) ?? [];
    setState(() {
      _conversationId = summary.id;
      _messages
        ..clear()
        ..addAll(summary.messages.map((s) => _Message(
              text: s.text,
              isUser: s.isUser,
              timestamp: s.timestamp,
            )));
      // Append any push notifications that arrived while this conv was away.
      for (final push in pendingPushes) {
        _messages.add(_Message(
          text: '**\u23f0 ${push.description}**\n\n${push.result}',
          isUser: false,
          timestamp: push.ts,
        ));
      }
      // Clear the visible stream buffer and remote-receive flag (switching display).
      // Do NOT touch _activeStreamConvId or _isLoading — a request may still
      // be in-flight for a different conversation; we keep blocking sends and
      // routing chunks until its response arrives.
      _streamBuffer = '';
      _progressMessage = '';
      _remoteStreamingConvId = null; // will be re-set when first chunk for new conv arrives
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  // ──────────────────────────────────────────────────────────
  //  BUILD
  // ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 600;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pembrook'),
        actions: [
          // New conversation icon
          IconButton(
            icon: const Icon(Icons.add_comment),
            tooltip: 'New conversation',
            onPressed: _newConversation,
          ),
          // History icon with badge showing unread background-response count.
          Consumer<RpcService>(
            builder: (context, rpc, _) {
              final count = rpc.unreadConvIds.length;
              return ExcludeSemantics(
                child: Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count'),
                  child: IconButton(
                    icon: const Icon(Icons.forum_outlined),
                    tooltip: 'Conversation history',
                    onPressed: _openHistory,
                  ),
                ),
              );
            },
          ),
          PopupMenuButton<_ChatAction>(
            tooltip: 'More options',
            onSelected: (action) {
              switch (action) {
                case _ChatAction.clearNotifications:
                  context.read<RpcService>().clearAllNotifications();
                  break;
                case _ChatAction.deleteChat:
                  _deleteCurrentConversation();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _ChatAction.clearNotifications,
                child: ListTile(
                  leading: Icon(Icons.notifications_off_outlined),
                  title: Text('Clear all notifications'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _ChatAction.deleteChat,
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete this conversation'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      drawer: wide ? null : _buildDrawer(context),
      body: Column(
        children: [
          // ── Agent config warning ───────────────────────────
          Consumer<RpcService>(
            builder: (context, rpc, _) {
              if (rpc.agentAtSign == '@agent') {
                return MaterialBanner(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  content: const Text(
                    'Agent atSign not configured. '
                    'Go to Settings and set your agent atSign.',
                  ),
                  leading: const Icon(Icons.warning_amber, color: Colors.orange),
                  actions: [
                    TextButton(
                      onPressed: () => context.go('/settings'),
                      child: const Text('Settings'),
                    ),
                  ],
                );
              }
              return const SizedBox.shrink();
            },
          ),
          Expanded(child: _buildMessages()),
          SafeArea(
            top: false,
            child: _buildInput(),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  MESSAGES LIST
  // ──────────────────────────────────────────────────────────

  Widget _buildMessages() {
    // Include progress message and streaming bubble as extra items if present
    final hasProgress = _progressMessage.isNotEmpty;
    final hasStreaming = _streamBuffer.isNotEmpty && _streamingEnabled;
    final extraItems = (hasProgress ? 1 : 0) + (hasStreaming ? 1 : 0);

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length + extraItems,
      itemBuilder: (context, index) {
        if (index < _messages.length) {
          final msg = _messages[index];
          return _ChatBubble(message: msg);
        } else if (hasProgress && index == _messages.length) {
          // Progress indicator (after all messages)
          return _ProgressIndicator(message: _progressMessage);
        } else {
          // Streaming bubble (last item)
          return _StreamingBubble(text: _streamBuffer);
        }
      },
    );
  }

  // ──────────────────────────────────────────────────────────
  //  INPUT ROW
  // ──────────────────────────────────────────────────────────

  Widget _buildInput() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputCtrl,
              maxLines: null,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                hintText: 'Message Pembrook…',
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: _isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton.filled(
                    icon: const Icon(Icons.send),
                    onPressed: _send,
                  ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  SEND
  // ──────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _isLoading) return;

    // Re-read pref on every send so Settings changes take effect immediately.
    final prefs = await SharedPreferences.getInstance();
    _streamingEnabled = prefs.getBool('streamingEnabled') ?? true;

    _inputCtrl.clear();
    setState(() {
      _messages.add(_Message(
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ));
      _isLoading = true;
      _streamBuffer = '';
      _activeStreamConvId = _conversationId; // open streaming window
    });
    // Record that THIS device initiated this conversation so _convCompletedSub
    // knows to let _send() manage the response rather than trying to load from
    // remote (which would race with the in-flight _persist() write).
    _originatedConvIds.add(_conversationId);
    // Immediately persist the question to the AtKey so Device B can display it
    // while the agent is streaming the answer.  _saveCurrentConversation() is
    // called again at the end of _send() to add the answer; the second save
    // simply overwrites with the complete exchange.
    _saveCurrentConversation();
    _scrollToBottom();

    final rpcService = context.read<RpcService>();
    // Capture the conversation this request belongs to.
    // If the user starts a new conversation while this call is in-flight,
    // the response must NOT appear in the new conversation.
    final sendConvId = _conversationId;
    final result = await rpcService.call(
      command: text,
      conversationId: _conversationId,
      payload: {'message': text},
      streamingEnabled: _streamingEnabled,
    );

    if (!mounted) return;

    // Grace period: keep the streaming window open for 2 seconds after RPC
    // returns to allow late chunks to arrive. This handles cases where the
    // agent signals completion (done: true) but chunks are still in-flight.
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    // Close the streaming window — late chunks have arrived.
    _activeStreamConvId = null;

    // Pick up streamed content: from the visible buffer if user stayed in this
    // conversation, or from the background buffer if they switched away.
    // Ignored entirely when streaming is disabled — always use RPC reply.
    final streamedText = _streamingEnabled
        ? (sendConvId == _conversationId ? _streamBuffer.trim() : (_bgStreamBuffers.remove(sendConvId) ?? '').trim())
        : '';
    final responseText = result.success
        ? (streamedText.isNotEmpty ? streamedText : result.response)
        : '⚠️ ${result.error ?? "Unknown error"}';

    if (sendConvId == _conversationId) {
      // Response arrived for the conversation currently on screen.
      setState(() {
        _isLoading = false;
        _streamBuffer = '';
        _progressMessage = ''; // Clear progress indicator
        _messages.add(_Message(
          text: responseText,
          isUser: false,
          timestamp: DateTime.now(),
        ));
      });
      _scrollToBottom();
      _saveCurrentConversation();
    } else {
      // User switched away while the request was in-flight.
      // Append the response to the backgrounded conversation in
      // ConversationStore so it's there when the user returns, then
      // surface a SnackBar with a direct "View" action.
      setState(() => _isLoading = false);
      final existing = _store?.get(sendConvId);
      if (existing != null) {
        final updated = ConversationSummary(
          id: existing.id,
          title: existing.title,
          createdAt: existing.createdAt,
          messages: [
            ...existing.messages,
            StoredMessage(
              text: responseText,
              isUser: false,
              timestamp: DateTime.now(),
            ),
          ],
        );
        await _store?.save(updated);
        // Mark this conversation as having unread content.
        _rpcService?.markConvUnread(sendConvId);
      }
      // Response saved silently — user will see it when they navigate
      // back to that conversation.
    }
  }

  // ──────────────────────────────────────────────────────────
  //  CONVERSATION MANAGEMENT
  // ──────────────────────────────────────────────────────────

  /// Start a fresh conversation: persist current first, then reset.
  void _newConversation() {
    _saveCurrentConversation();
    setState(() {
      _conversationId = _uuid.v4();
      _messages
        ..clear()
        ..add(_Message(text: _welcomeText, isUser: false));
      // Clear the visible stream buffer and remote-receive flag.
      // Do NOT touch _activeStreamConvId or _isLoading — a request may still
      // be in-flight; we keep blocking sends and routing chunks until it lands.
      _streamBuffer = '';
      _progressMessage = '';
      _remoteStreamingConvId = null;
    });
  }

  /// Open the history screen.  If the user picks a conversation, load it.
  Future<void> _openHistory() async {
    // Save current before navigating away.
    _saveCurrentConversation();
    final summary = await context.push<ConversationSummary?>('/history');
    if (summary != null && mounted) {
      _loadConversation(summary);
    }
  }

  /// Delete the current conversation and start a fresh one.
  void _deleteCurrentConversation() {
    final convId = _conversationId;
    _store?.delete(convId);
    _rpcService?.markConvRead(convId); // clear any unread badge for it
    setState(() {
      _conversationId = _uuid.v4();
      _messages
        ..clear()
        ..add(_Message(text: _welcomeText, isUser: false));
      _streamBuffer = '';
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Returns true when [conv] contains at least one user message AND at least
  /// one agent reply that comes AFTER the last user message.
  /// Used to distinguish a question-only snapshot (written by Device A at the
  /// start of _send()) from a complete exchange.
  bool _isConversationComplete(ConversationSummary? conv) {
    if (conv == null) return false;
    final msgs = conv.messages;
    final lastUserIdx = msgs.lastIndexWhere((m) => m.isUser);
    if (lastUserIdx < 0) return false; // no question at all
    return msgs.length > lastUserIdx + 1; // agent reply exists after question
  }

  Future<void> _signOut() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will be signed out. Your keys remain on this device '
            'so you can sign back in at any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    // ignore: use_build_context_synchronously
    context.read<RpcService>().signOut();
    // ignore: use_build_context_synchronously
    if (mounted) context.go('/auth');
  }

  // ──────────────────────────────────────────────────────────
  //  DRAWER
  // ──────────────────────────────────────────────────────────

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.security, size: 40, color: Theme.of(context).colorScheme.onPrimaryContainer),
                const SizedBox(height: 8),
                Text('Pembrook',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        )),
                Text('Secure AI Agent',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                        )),
              ],
            ),
          ),
          _DrawerItem(Icons.chat, 'Chat', '/home', context),
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('History'),
            onTap: () {
              Navigator.pop(context);
              _openHistory();
            },
          ),
          _DrawerItem(Icons.article, 'Audit Log', '/audit', context),
          _DrawerItem(Icons.extension, 'Skills', '/skills', context),
          _DrawerItem(Icons.pending_actions, 'Approvals', '/hitl', context),
          const Divider(),
          _DrawerItem(Icons.settings, 'Settings', '/settings', context),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Sign out', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(context);
              _signOut();
            },
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

Widget _DrawerItem(IconData icon, String label, String route, BuildContext context) {
  return ListTile(
    leading: Icon(icon),
    title: Text(label),
    onTap: () {
      Navigator.pop(context);
      context.go(route);
    },
  );
}

// ──────────────────────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final _Message message;

  const _ChatBubble({required this.message});

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    // Wrap the ENTIRE bubble in a single flat Semantics node.
    // ExcludeSemantics covers everything inside — including GestureDetector
    // (which registers an onLongPress action node) and MarkdownBody.
    //
    // MarkdownBody(selectable: true) creates a SelectionArea widget which
    // registers its OWN SemanticsNode independently, bypassing ExcludeSemantics.
    // selectable: false removes SelectionArea entirely. Long-press copy still
    // works because GestureDetector receives touches regardless of semantics.
    return Semantics(
      label: isUser ? 'You: ${message.text}' : message.text,
      child: ExcludeSemantics(
        child: Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: () => _copyToClipboard(context),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              decoration: BoxDecoration(
                color: isUser
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: isUser
                  ? Text(
                      message.text,
                      softWrap: true,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : MarkdownBody(
                      data: message.text,
                      selectable: false,
                      softLineBreak: true,
                      onTapLink: (text, href, title) {
                        if (href != null) {
                          launchUrl(
                            Uri.parse(href),
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      },
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                        p: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                        code: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                        codeblockPadding: const EdgeInsets.all(12),
                        codeblockDecoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        blockquoteDecoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: Theme.of(context).colorScheme.primary,
                              width: 3,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  final String text;

  const _StreamingBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    // ExcludeSemantics: this widget rebuilds on every streaming token.
    // Exposing a partially-complete message to the Windows AX bridge causes
    // rapid AXTree node churn → accessibility_bridge errors.  The fully
    // rendered message bubble gets its own Semantics node once streaming ends.
    return ExcludeSemantics(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  text,
                  softWrap: true,
                ),
              ),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────
//  PROGRESS INDICATOR (ephemeral status message)
// ──────────────────────────────────────────────────────────

class _ProgressIndicator extends StatelessWidget {
  final String message;
  const _ProgressIndicator({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ExcludeSemantics: ephemeral progress text + animated spinner cause
    // continuous AXTree updates.  Screen-readers gain nothing from partially
    // rendered progress strings; the final assistant bubble is accessible.
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            // Left-aligned (agent message)
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      softWrap: true,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
