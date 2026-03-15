/// ChatScreen — the main Pembrook conversation UI.
///
/// Sends messages to @agent via RpcService.call() and renders the response.
/// Subscribes to RpcService.streamChunkEvents for incremental token rendering
/// (streaming mode from the agent). Chunks are filtered by conversationId so
/// only the screen that sent the request renders its own response.
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
//  ChatScreen
// ─────────────────────────────────────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
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
  StreamSubscription<StreamChunkEvent>? _streamSub;
  StreamSubscription<PushMessage>? _pushSub;

  static const String _welcomeText =
      'Hello! I\'m your Pembrook AI assistant. All our communication is '
      'end-to-end encrypted via the atPlatform. How can I help you today?';

  @override
  void initState() {
    super.initState();
    _conversationId = _uuid.v4();
    _messages.add(_Message(text: _welcomeText, isUser: false));
    // Load the stored conversation list on first launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _store = context.read<ConversationStore>();
      _store?.load();
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
      if (!_streamingEnabled) return; // streaming disabled in Settings
      if (event.conversationId != _activeStreamConvId) return;
      if (event.conversationId == _conversationId) {
        // Chunk for the currently displayed conversation.
        setState(() => _streamBuffer += event.chunk);
        _scrollToBottom();
      } else {
        // Chunk for a backgrounded in-flight conversation — buffer it.
        _bgStreamBuffers[event.conversationId] =
            (_bgStreamBuffers[event.conversationId] ?? '') + event.chunk;
      }
    });
    // Subscribe to proactive push messages from scheduled tasks.
    // listenToPushMessages() also drains any messages that arrived while
    // this screen was unmounted (e.g. user was on Settings/Skills screen).
    _pushSub?.cancel();
    _pushSub = _rpcService!.listenToPushMessages((push) {
      final header = '**\u23f0 ${push.description}**\n\n';
      if (!mounted) return;
      setState(() {
        _messages.add(_Message(
          text: '$header${push.result}',
          isUser: false,
          timestamp: push.ts,
        ));
      });
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    // Persist the current conversation before the screen disposes.
    _saveCurrentConversation();
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _streamSub?.cancel();
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
    final title = userMessages.first.text.length > 80
        ? '${userMessages.first.text.substring(0, 77)}…'
        : userMessages.first.text;

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
    setState(() {
      _conversationId = summary.id;
      _messages
        ..clear()
        ..addAll(summary.messages.map((s) => _Message(
              text: s.text,
              isUser: s.isUser,
              timestamp: s.timestamp,
            )));
      // Clear the visible stream buffer (switching display).
      // Do NOT touch _activeStreamConvId or _isLoading — a request may still
      // be in-flight for a different conversation; we keep blocking sends and
      // routing chunks until its response arrives.
      _streamBuffer = '';
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
          IconButton(
            icon: const Icon(Icons.forum_outlined),
            tooltip: 'Conversation history',
            onPressed: _openHistory,
          ),
          IconButton(
            icon: const Icon(Icons.add_comment),
            tooltip: 'New conversation',
            onPressed: _newConversation,
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
                  leading:
                      const Icon(Icons.warning_amber, color: Colors.orange),
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
          if (_streamBuffer.isNotEmpty && _streamingEnabled)
            _StreamingBubble(text: _streamBuffer),
          _buildInput(),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────
  //  MESSAGES LIST
  // ──────────────────────────────────────────────────────────

  Widget _buildMessages() {
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return _ChatBubble(message: msg);
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
          _isLoading
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
    );

    if (!mounted) return;

    // Close the streaming window unconditionally — we have the full response.
    _activeStreamConvId = null;

    // Pick up streamed content: from the visible buffer if user stayed in this
    // conversation, or from the background buffer if they switched away.
    // Ignored entirely when streaming is disabled — always use RPC reply.
    final streamedText = _streamingEnabled
        ? (sendConvId == _conversationId
            ? _streamBuffer.trim()
            : (_bgStreamBuffers.remove(sendConvId) ?? '').trim())
        : '';
    final responseText = result.success
        ? (streamedText.isNotEmpty ? streamedText : result.response)
        : '⚠️ ${result.error ?? "Unknown error"}';

    if (sendConvId == _conversationId) {
      // Response arrived for the conversation currently on screen.
      setState(() {
        _isLoading = false;
        _streamBuffer = '';
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
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Pembrook responded in a previous conversation'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () {
              final summary = _store?.get(sendConvId);
              if (summary != null) _loadConversation(summary);
            },
          ),
        ));
      }
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
      // Clear the visible stream buffer (switching display).
      // Do NOT touch _activeStreamConvId or _isLoading — a request may still
      // be in-flight; we keep blocking sends and routing chunks until it lands.
      _streamBuffer = '';
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
                Icon(Icons.security,
                    size: 40,
                    color: Theme.of(context).colorScheme.onPrimaryContainer),
                const SizedBox(height: 8),
                Text('Pembrook',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        )),
                Text('Secure AI Agent',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
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
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────

Widget _DrawerItem(
    IconData icon, String label, String route, BuildContext context) {
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

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: isUser
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: isUser
            ? SelectableText(
                message.text,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              )
            : MarkdownBody(
                data: message.text,
                selectable: true,
                onTapLink: (text, href, title) {
                  if (href != null) {
                    launchUrl(
                      Uri.parse(href),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                styleSheet:
                    MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                  p: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                  code: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
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
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  final String text;

  const _StreamingBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Theme.of(context).colorScheme.primary, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(text)),
            const SizedBox(width: 8),
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}
