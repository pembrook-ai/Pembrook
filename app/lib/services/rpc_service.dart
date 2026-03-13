/// RpcService — Flutter app side of the AtRpc communication with @agent.
///
/// Uses [AtRpcClient] from at_client — the same protocol the agent's Gateway
/// uses on the server side.  Key format:
///   request.<reqId>.<domainNS>.<rpcsNS>.<baseNS>  → to @agent
///   success.<reqId>.<domainNS>.<rpcsNS>.<baseNS>  ← from @agent
///
/// AtRpc namespaces (must match agent/lib/gateway/gateway.dart exactly):
///   baseNameSpace   = 'safeclaw'
///   rpcsNameSpace   = '__rpcs'   (AtRpc default)
///   domainNameSpace = 'safeclaw'
///
/// Agent atSign: read from SharedPreferences key 'agentAtSign'.
///   Set once in SettingsScreen.  Call [updateAgentAtSign] after saving
///   there so the client is recreated immediately without a restart.
///
/// Streaming:
///   [streamChunks] — a Stream<String> yielding incremental tokens sent by
///   the Orchestrator as 'safeclaw.stream.<reqId>.safeclaw' notifications.
///   The final full response still arrives via the normal AtRpc reply.

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

class RpcService extends ChangeNotifier {
  AtClient? _atClient;
  AtRpcClient? _rpcClient;
  StreamSubscription<AtNotification>? _streamSubscription;

  String _agentAtSign = '@agent';

  static const String _baseNS = 'safeclaw';
  static const String _rpcsNS = '__rpcs';
  static const String _domainNS = 'safeclaw';

  /// How long to wait for an agent response before giving up.
  static const Duration _callTimeout = Duration(seconds: 90);

  // Stream of incremental text chunks from the agent (streaming mode).
  final StreamController<String> _streamChunkController =
      StreamController<String>.broadcast();

  Stream<String> get streamChunks => _streamChunkController.stream;
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
  Future<RpcCallResult> call({
    required String command,
    required String conversationId,
    Map<String, dynamic> payload = const {},
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
        .subscribe(regex: r'safeclaw\.stream\..*', shouldDecrypt: true)
        .listen((notification) {
      if (notification.value == null) return;
      try {
        // The orchestrator sends stream chunks as plain text, not JSON.
        // Handle both: plain string and {"chunk": "..."} JSON envelope.
        final value = notification.value!;
        String chunk;
        if (value.startsWith('{')) {
          final map = _tryDecode(value);
          chunk = map?['chunk'] as String? ?? value;
        } else {
          chunk = value;
        }
        if (chunk.isNotEmpty) _streamChunkController.add(chunk);
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
    _streamChunkController.close();
    super.dispose();
  }
}
