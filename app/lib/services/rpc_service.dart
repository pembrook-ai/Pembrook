/// RpcService — Flutter app side of the AtRpc communication with @agent.
///
/// Uses [AtRpcClient] from at_client — the same protocol the agent's Gateway
/// uses on the server side.  Key format:
///   request.<reqId>.<domainNS>.<rpcsNS>.<baseNS>  → to @agent
///   success.<reqId>.<domainNS>.<rpcsNS>.<baseNS>  ← from @agent
///
/// AtRpc namespaces (must match agent/lib/gateway/gateway.dart exactly):
///   baseNameSpace   = 'pembrook'
///   rpcsNameSpace   = '__rpcs'   (AtRpc default)
///   domainNameSpace = 'pembrook'
///
/// Agent atSign: read from SharedPreferences key 'agentAtSign'.
///   Set once in SettingsScreen.  Call [updateAgentAtSign] after saving
///   there so the client is recreated immediately without a restart.
///
/// Streaming:
///   [streamChunkEvents] — a Stream<StreamChunkEvent> yielding incremental tokens
///   sent by the Orchestrator as 'pembrook.stream.<reqId>.<i>.pembrook' notifications.
///   Each event carries a [conversationId] so ChatScreen can filter to its own chunks.
///   The final full response still arrives via the normal AtRpc reply.
///
/// Cross-device sync:
///   [conversationCompletedEvents] — a Stream<String> that fires a conversationId
///   whenever the agent sends a 'done: true' stream chunk.  Other devices receive
///   this notification too (atPlatform broadcasts to all subscribers of @owner) and
///   use it as a trigger to reload the shared conversation_history AtKey.

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RpcCallResult {
  final bool success;
  final String response;
  final String conversationId;
  final String? error;

  const RpcCallResult({
    required this.success,
    required this.response,
    required this.conversationId,
    this.error,
  });
}

/// A streaming chunk event — carries the conversationId it belongs to so
/// each ChatScreen can filter and only render its own conversation's chunks.
class StreamChunkEvent {
  final String conversationId;
  final String chunk;
  const StreamChunkEvent({required this.conversationId, required this.chunk});
}

/// A proactive push message sent by the agent from a scheduled task.
class PushMessage {
  final String taskId;
  final String description;
  final String result;
  final DateTime ts;

  const PushMessage({
    required this.taskId,
    required this.description,
    required this.result,
    required this.ts,
  });
}

class RpcService extends ChangeNotifier {
  AtClient? _atClient;
  AtRpcClient? _rpcClient;
  StreamSubscription<AtNotification>? _streamSubscription;
  StreamSubscription<AtNotification>? _pushSubscription;

  String _agentAtSign = '@agent';

  static const String _baseNS = 'pembrook';
  static const String _rpcsNS = '__rpcs';
  static const String _domainNS = 'pembrook';

  /// How long to wait for an agent response before giving up.
  static const Duration _callTimeout = Duration(seconds: 90);

  // Stream of incremental text chunks from the agent (streaming mode).
  // Each event carries the conversationId it belongs to so individual
  // ChatScreens can filter to only their own conversation's chunks.
  final StreamController<StreamChunkEvent> _streamChunkController =
      StreamController<StreamChunkEvent>.broadcast();

  // Fires the conversationId whenever a 'done: true' stream chunk is received.
  // Used by other devices to detect that a conversation was completed elsewhere
  // and to reload the shared conversation_history AtKey.
  final StreamController<String> _convCompletedController =
      StreamController<String>.broadcast();

  // Stream of proactive push messages from scheduled tasks.
  final StreamController<PushMessage> _pushController =
      StreamController<PushMessage>.broadcast();

  // Buffer that accumulates push messages while ChatScreen is not mounted.
  // Drained by ChatScreen.didChangeDependencies() via listenToPushMessages().
  final List<PushMessage> _pushBuffer = [];

  // True while ChatScreen has an active push subscription.
  // Suppresses buffering so messages aren't shown twice on remount.
  bool _hasPushListener = false;

  /// Stream of chunk events keyed by conversationId.
  /// ChatScreen should filter: `streamChunkEvents.where((e) => e.conversationId == _conversationId)`
  Stream<StreamChunkEvent> get streamChunkEvents =>
      _streamChunkController.stream;

  /// Fires a conversationId each time the agent signals 'done: true' on a
  /// stream chunk.  All devices subscribed to @owner receive this notification,
  /// so those that didn't originate the request can use it as a cue to reload
  /// the shared conversation_history AtKey and show the completed exchange.
  Stream<String> get conversationCompletedEvents =>
      _convCompletedController.stream;

  /// Subscribe to push messages, draining any that arrived while away.
  ///
  /// Call from ChatScreen.didChangeDependencies().
  /// Call releasePushListener() from ChatScreen.dispose() BEFORE cancelling.
  StreamSubscription<PushMessage> listenToPushMessages(
      void Function(PushMessage) onMessage) {
    _hasPushListener = true;
    // Deliver messages that arrived while the screen was unmounted.
    final buffered = List<PushMessage>.from(_pushBuffer);
    _pushBuffer.clear();
    for (final msg in buffered) {
      onMessage(msg);
    }
    return _pushController.stream.listen(onMessage);
  }

  /// Call from ChatScreen.dispose() to re-enable buffering.
  void releasePushListener() => _hasPushListener = false;

  bool get isAuthenticated => _atClient != null;
  String get agentAtSign => _agentAtSign;

  /// Called by auth walkthrough after a successful login.
  Future<void> initialise(AtClient atClient) async {
    _atClient = atClient;
    await _loadAgentAtSign();
    _initRpcClient();
    _subscribeToStream();
    notifyListeners();
  }

  /// Called by SettingsScreen when the user saves a new agent atSign.
  /// Recreates the AtRpcClient so calls immediately use the new address.
  Future<void> updateAgentAtSign(String newAtSign) async {
    final trimmed = newAtSign.trim();
    if (trimmed == _agentAtSign) return;
    _agentAtSign = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agentAtSign', trimmed);
    _initRpcClient();
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────
  //  CALL
  // ──────────────────────────────────────────────────────────

  /// Send a command to @agent and wait for its response.
  ///
  /// [streamingEnabled] — when false, the agent skips sending stream chunk
  /// notifications and returns the full response only in the RPC reply.
  /// This matches the Flutter "Show tokens as they arrive" preference and
  /// saves significant latency when the user has streaming turned off.
  Future<RpcCallResult> call({
    required String command,
    required String conversationId,
    Map<String, dynamic> payload = const {},
    bool streamingEnabled = true,
  }) async {
    if (_rpcClient == null) {
      return const RpcCallResult(
        success: false,
        response: '',
        conversationId: '',
        error: 'Not authenticated — please log in',
      );
    }

    try {
      final result = await _rpcClient!.call({
        'command': command,
        'conversationId': conversationId,
        'platform': _platformName(),
        'streamingEnabled': streamingEnabled,
        ...payload,
      }).timeout(_callTimeout);

      return RpcCallResult(
        success: result['success'] as bool? ?? true,
        response: result['response'] as String? ?? '',
        conversationId: result['conversationId'] as String? ?? conversationId,
        error: result['error'] as String?,
      );
    } on TimeoutException {
      return RpcCallResult(
        success: false,
        response: '',
        conversationId: conversationId,
        error: 'Request timed out after '
            '${_callTimeout.inSeconds}s — is the agent running?',
      );
    } catch (e) {
      return RpcCallResult(
        success: false,
        response: '',
        conversationId: conversationId,
        error: 'RPC error: $e',
      );
    }
  }

  // ──────────────────────────────────────────────────────────
  //  HELPERS
  // ──────────────────────────────────────────────────────────

  Future<void> _loadAgentAtSign() async {
    final prefs = await SharedPreferences.getInstance();
    _agentAtSign = prefs.getString('agentAtSign') ?? '@agent';
  }

  void _initRpcClient() {
    if (_atClient == null) return;
    _rpcClient = AtRpcClient(
      serverAtsign: _agentAtSign,
      atClient: _atClient!,
      baseNameSpace: _baseNS,
      rpcsNameSpace: _rpcsNS,
      domainNameSpace: _domainNS,
    );
  }

  void _subscribeToStream() {
    _streamSubscription?.cancel();
    _streamSubscription = _atClient!.notificationService
        .subscribe(regex: r'pembrook\.stream\..*', shouldDecrypt: true)
        .listen((notification) {
      if (notification.value == null) return;
      try {
        // The orchestrator sends stream chunks as plain text, not JSON.
        // Handle both: plain string and {"chunk": "..."} JSON envelope.
        final value = notification.value!;
        String chunk;
        String convId = '';
        bool isDone = false;
        if (value.startsWith('{')) {
          final map = _tryDecode(value);
          chunk = map?['chunk'] as String? ?? value;
          convId = map?['conversationId'] as String? ?? '';
          isDone = map?['done'] as bool? ?? false;
        } else {
          chunk = value;
        }
        if (chunk.isNotEmpty) {
          _streamChunkController
              .add(StreamChunkEvent(conversationId: convId, chunk: chunk));
        }
        // Signal completion so other devices can reload conversation history.
        if (isDone && convId.isNotEmpty) {
          _convCompletedController.add(convId);
        }
      } catch (_) {}
    });

    // Also subscribe to scheduled-task push messages from the agent.
    _pushSubscription?.cancel();
    _pushSubscription = _atClient!.notificationService
        .subscribe(regex: r'pembrook\.push\..*', shouldDecrypt: true)
        .listen((notification) {
      if (notification.value == null) return;
      try {
        final map = _tryDecode(notification.value!);
        if (map == null) return;
        final push = PushMessage(
          taskId: map['taskId'] as String? ?? '',
          description: map['description'] as String? ?? 'Scheduled task result',
          result: map['result'] as String? ?? '',
          ts: DateTime.fromMillisecondsSinceEpoch(
              (map['ts'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch),
        );
        if (push.result.isNotEmpty) {
          // Buffer only when ChatScreen is not actively listening.
          if (!_hasPushListener) _pushBuffer.add(push);
          _pushController.add(push);
        }
      } catch (_) {}
    });
  }

  Map<String, dynamic>? _tryDecode(String s) {
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  String _platformName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _pushSubscription?.cancel();
    _streamChunkController.close();
    _convCompletedController.close();
    _pushController.close();
    super.dispose();
  }
}
