/// GatewayCallbacks — AtRpcCallbacks implementation for the agent gateway.
///
/// handleRequest() is called by AtRpc for every validated inbound RPC call.
/// AtRpc itself enforces that the sender is in the allowList before calling
/// handleRequest — we perform additional checks here.
///
/// Request payload schema (from Flutter app or bridge):
///   {
///     "command": "string — the user's instruction",
///     "conversationId": "optional string — for conversation continuity",
///     "timestamp": "int — Unix ms",
///     "senderAtSign": "optional string — real owner atSign (set by bridges)",
///     "platform": "optional string — 'app' | 'whatsapp' | 'telegram' etc."
///   }
///
/// Response payload schema:
///   {
///     "success": bool,
///     "response": "string — full response (non-streaming) OR empty (streaming)",
///     "streaming": bool,
///     "conversationId": "string",
///     "error": "string — present only on failure"
///   }

import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../core/orchestrator.dart';
import '../core/policy_engine.dart';
import '../services/audit_service.dart';
import '../models/audit_entry.dart';
import '../models/policy.dart';

/// Per-sender rate limit: max requests within window.
const int kRateLimitMaxRequests = 60;
const Duration kRateLimitWindow = Duration(minutes: 1);

class GatewayCallbacks implements AtRpcCallbacks {
  final Orchestrator orchestrator;
  final PolicyEngine policyEngine;
  final AuditService auditService;

  final Logger _log = Logger('GatewayCallbacks');

  // In-memory rate limit tracker: atSign → [request timestamps]
  final Map<String, List<DateTime>> _rateLimitTracker = {};

  GatewayCallbacks({
    required this.orchestrator,
    required this.policyEngine,
    required this.auditService,
  });

  @override
  Future<AtRpcResp> handleRequest(AtRpcReq request, String fromAtSign) async {
    final startTime = DateTime.now();
    _log.info('Received request from $fromAtSign — reqId=${request.reqId}');

    try {
      // ── 1. Extract payload ──────────────────────────────────────────────
      final payload = request.payload;
      final command = payload['command'] as String? ?? '';
      final conversationId =
          payload['conversationId'] as String? ?? _generateConversationId();
      // For bridge messages, the real owner atSign is embedded in the payload.
      // A compromised bridge cannot forge this — we verify it against the
      // owner atSign registered in policy.
      final effectiveSender = payload['senderAtSign'] as String? ?? fromAtSign;
      final platform = payload['platform'] as String? ?? 'app';

      if (command.isEmpty) {
        return _errorResponse(request.reqId, 'Empty command');
      }

      // ── 2. Rate limit check ─────────────────────────────────────────────
      if (!_checkRateLimit(fromAtSign)) {
        _log.warning('Rate limit exceeded for $fromAtSign');
        await auditService.log(AuditEntry(
          actionType: 'rate_limit_exceeded',
          initiatorAtSign: fromAtSign,
          targetResource: 'gateway',
          policyDecision: 'denied',
          inputHash: _hash(command),
        ));
        return _errorResponse(request.reqId, 'Rate limit exceeded');
      }

      // ── 3. Policy check — identity and capability ───────────────────────
      final policyDecision = await policyEngine.checkPolicy(
        PolicyCheckRequest(
          action: 'chat_command',
          senderAtSign: fromAtSign,
          effectiveOwnerAtSign: effectiveSender,
          platform: platform,
          command: command,
        ),
      );

      if (!policyDecision.allowed) {
        _log.warning(
            'Policy denied command from $fromAtSign: ${policyDecision.reason}');
        await auditService.log(AuditEntry(
          actionType: 'command',
          initiatorAtSign: fromAtSign,
          targetResource: 'orchestrator',
          policyDecision: 'denied',
          inputHash: _hash(command),
          notes: policyDecision.reason,
        ));
        return _errorResponse(
            request.reqId, 'Policy denied: ${policyDecision.reason}');
      }

      // ── 4. Delegate to orchestrator ─────────────────────────────────────
      final result = await orchestrator.processRequest(
        command: command,
        conversationId: conversationId,
        fromAtSign: effectiveSender,
        platform: platform,
        reqId: request.reqId,
      );

      final elapsed = DateTime.now().difference(startTime).inMilliseconds;

      await auditService.log(AuditEntry(
        actionType: 'command',
        initiatorAtSign: fromAtSign,
        targetResource: 'orchestrator',
        policyDecision: 'allowed',
        inputHash: _hash(command),
        outputHash: _hash(result['response'] as String? ?? ''),
        executionDurationMs: elapsed,
      ));

      return AtRpcResp(
        reqId: request.reqId,
        respType: AtRpcRespType.success,
        payload: result,
      );
    } catch (e, stack) {
      _log.severe('Unhandled error in handleRequest', e, stack);
      return _errorResponse(request.reqId, 'Internal error: $e');
    }
  }

  @override
  Future<void> handleResponse(AtRpcResp response) async {
    // The gateway acts as a server — we don't initiate outbound RPCs here.
    // This callback is invoked if we ever call rpc.call(); unused for now.
    _log.fine('Received response: ${response.reqId}');
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  bool _checkRateLimit(String atSign) {
    final now = DateTime.now();
    final windowStart = now.subtract(kRateLimitWindow);
    final history = _rateLimitTracker.putIfAbsent(atSign, () => []);
    history.removeWhere((t) => t.isBefore(windowStart));
    if (history.length >= kRateLimitMaxRequests) return false;
    history.add(now);
    return true;
  }

  AtRpcResp _errorResponse(int reqId, String message) {
    return AtRpcResp(
      reqId: reqId,
      respType: AtRpcRespType.error,
      payload: {'success': false, 'error': message},
    );
  }

  String _generateConversationId() =>
      'conv-${DateTime.now().millisecondsSinceEpoch}';

  String _hash(String value) {
    // Simple hex encoding for audit purposes.
    // In production, use crypto package for SHA-256.
    return 'hash:${value.hashCode.toRadixString(16)}';
  }
}
