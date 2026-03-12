/// RpcService — Flutter app side of the AtRpc communication with @agent.
///
/// USAGE:
///   final rpcService = context.read<RpcService>();
///   final response = await rpcService.call(
///     command: 'chat',
///     conversationId: _conversationId,
///     payload: {'message': userInput},
///   );
///
/// Streaming:
///   rpcService.streamChunks — a Stream<String> that yields incremental
///   response tokens from 'safeclaw.stream.*' notifications.
///
/// All calls are encrypted by the atClient SDK — the agent's atServer
/// decrypts on the other end. No plaintext on any server.
///
/// Agent atSign: @agent (placeholder — set via SettingsScreen).

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/foundation.dart';

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
  StreamSubscription<AtNotification>? _streamSubscription;

  static const String _agentAtSign = '@agent'; // placeholder
  static const String _namespace = 'safeclaw';

  // Stream of incremental text chunks from the agent.
  final StreamController<String> _streamChunkController =
      StreamController<String>.broadcast();

  Stream<String> get streamChunks => _streamChunkController.stream;
  bool get isAuthenticated => _atClient != null;

  void initialise(AtClient atClient) {
    _atClient = atClient;
    _subscribeToStream();
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────
  //  CALL
  // ──────────────────────────────────────────────────────────

  /// Send a command to the @agent and wait for its response.
  Future<RpcCallResult> call({
    required String command,
    required String conversationId,
    Map<String, dynamic> payload = const {},
  }) async {
    if (_atClient == null) {
      return const RpcCallResult(
        success: false,
        response: '',
        conversationId: '',
        error: 'Not authenticated',
      );
    }

    final reqId = DateTime.now().millisecondsSinceEpoch;
    final envelope = jsonEncode({
      'command': command,
      'conversationId': conversationId,
      'platform': _platformName(),
      'reqId': reqId,
      ...payload,
    });

    // Send request as a notification to @agent
    final requestKey = (AtKey.shared(
      'safeclaw.cmd.$reqId',
      namespace: _namespace,
      sharedBy: _atClient!.getCurrentAtSign() ?? '',
    )..sharedWith(_agentAtSign))
        .build()
      ..metadata = (Metadata()
        ..ttl = 60000 // 1 min TTL
        ..ttr = -1);

    try {
      await _atClient!.notificationService.notify(
        NotificationParams.forUpdate(requestKey, value: envelope),
      );

      // Wait for response on 'safeclaw.cmd.response.$reqId'
      final response = await _waitForResponse(
          'safeclaw\\.cmd\\.response\\.$reqId',
          timeout: const Duration(seconds: 60));

      if (response == null) {
        return RpcCallResult(
          success: false,
          response: '',
          conversationId: conversationId,
          error: 'Request timed out',
        );
      }

      final map = jsonDecode(response) as Map<String, dynamic>;
      return RpcCallResult(
        success: map['success'] as bool? ?? false,
        response: map['response'] as String? ?? '',
        conversationId: map['conversationId'] as String? ?? conversationId,
        error: map['error'] as String?,
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
  //  STREAMING SUBSCRIPTION
  // ──────────────────────────────────────────────────────────

  void _subscribeToStream() {
    _streamSubscription?.cancel();
    _streamSubscription = _atClient!.notificationService
        .subscribe(regex: r'safeclaw\.stream\..*', shouldDecrypt: true)
        .listen((notification) {
      if (notification.value != null) {
        try {
          final map = jsonDecode(notification.value!) as Map<String, dynamic>;
          final chunk = map['chunk'] as String? ?? '';
          if (chunk.isNotEmpty) {
            _streamChunkController.add(chunk);
          }
        } catch (_) {}
      }
    });
  }

  Future<String?> _waitForResponse(String keyPattern,
      {required Duration timeout}) async {
    final completer = Completer<String?>();
    StreamSubscription<AtNotification>? sub;
    Timer? timer;

    sub = _atClient!.notificationService
        .subscribe(regex: keyPattern, shouldDecrypt: true)
        .listen((notification) {
      if (!completer.isCompleted && notification.value != null) {
        completer.complete(notification.value);
      }
    });

    timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    final result = await completer.future;
    await sub.cancel();
    timer.cancel();
    return result;
  }

  String _platformName() {
    if (kIsWeb) return 'web';
    try {
      // Platform is not available on web
      if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
      if (defaultTargetPlatform == TargetPlatform.android) return 'android';
      if (defaultTargetPlatform == TargetPlatform.macOS) return 'macos';
      if (defaultTargetPlatform == TargetPlatform.windows) return 'windows';
      if (defaultTargetPlatform == TargetPlatform.linux) return 'linux';
    } catch (_) {}
    return 'unknown';
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _streamChunkController.close();
    super.dispose();
  }
}
