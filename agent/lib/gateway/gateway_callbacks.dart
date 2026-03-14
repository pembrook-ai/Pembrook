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
/// System command schema (management commands, NOT sent to orchestrator):
///   {
///     "command": "_sys.skill.install | _sys.skill.uninstall | _sys.skill.list",
///     "conversationId": "sys",
///     ...payload fields...
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
import 'package:uuid/uuid.dart';

import '../core/orchestrator.dart';
import '../core/policy_engine.dart';
import '../services/audit_service.dart';
import '../skills/registry.dart';
import '../models/skill_metadata.dart';
import '../models/audit_entry.dart';
import '../models/policy.dart';

/// Per-sender rate limit: max requests within window.
const int kRateLimitMaxRequests = 60;
const Duration kRateLimitWindow = Duration(minutes: 1);

class GatewayCallbacks implements AtRpcCallbacks {
  final Orchestrator orchestrator;
  final PolicyEngine policyEngine;
  final AuditService auditService;

  /// Optional skill registry — required for _sys.skill.* management commands.
  final SkillRegistry? skillRegistry;

  final Logger _log = Logger('GatewayCallbacks');
  final Uuid _uuid = const Uuid();

  // In-memory rate limit tracker: atSign → [request timestamps]
  final Map<String, List<DateTime>> _rateLimitTracker = {};

  GatewayCallbacks({
    required this.orchestrator,
    required this.policyEngine,
    required this.auditService,
    this.skillRegistry,
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

      // ── 3. System management commands (bypass orchestrator) ─────────────
      if (command.startsWith('_sys.')) {
        return await _handleSysCommand(
          command: command,
          payload: payload,
          fromAtSign: fromAtSign,
          reqId: request.reqId,
        );
      }

      // ── 4. Policy check — identity and capability ───────────────────────
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

      // ── 5. Delegate to orchestrator ─────────────────────────────────────
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

  // ── System Commands ───────────────────────────────────────────────────────

  /// Handle _sys.* management commands without touching the orchestrator.
  ///
  /// Currently supported:
  ///   _sys.skill.install   — register a skill in the registry
  ///   _sys.skill.uninstall — remove a skill by skillId
  ///   _sys.skill.list      — return JSON array of all installed skills
  Future<AtRpcResp> _handleSysCommand({
    required String command,
    required Map<String, dynamic> payload,
    required String fromAtSign,
    required int reqId,
  }) async {
    _log.info('Sys command: $command from $fromAtSign');

    if (skillRegistry == null) {
      return _errorResponse(reqId, 'SkillRegistry not wired — cannot manage skills');
    }

    try {
      switch (command) {
        case '_sys.skill.install':
          return await _sysSkillInstall(payload, fromAtSign, reqId);
        case '_sys.skill.uninstall':
          return await _sysSkillUninstall(payload, reqId);
        case '_sys.skill.list':
          return await _sysSkillList(reqId);
        default:
          return _errorResponse(reqId, 'Unknown sys command: $command');
      }
    } catch (e) {
      _log.warning('Sys command error ($command): $e');
      return _errorResponse(reqId, 'Sys command failed: $e');
    }
  }

  Future<AtRpcResp> _sysSkillInstall(
    Map<String, dynamic> payload,
    String fromAtSign,
    int reqId,
  ) async {
    final skillId = payload['skillId'] as String? ?? '';
    if (skillId.isEmpty) {
      return _errorResponse(reqId, 'skillId is required');
    }

    // Convert SkillData (app model) → SkillMetadata (agent model).
    // Fields not present in the app model get safe defaults.
    final meta = SkillMetadata(
      skillId: skillId,
      skillAtSign: payload['skillAtSign'] as String? ?? fromAtSign,
      developerAtSign: fromAtSign, // owner is the "developer" for app-registered skills
      signatureHash: 'app-registered-${_uuid.v4()}',
      version: payload['version'] as String? ?? '1.0.0',
      declaredCapabilities: const SkillCapabilities(),
      trustScore: (payload['trustScore'] as num?)?.toDouble() ?? 0.5,
      installedAt: DateTime.now().toUtc(),
      lastAuditResult: 'app-registered',
      ownerPolicyOverrides: {
        if (payload['config'] is Map)
          ...Map<String, dynamic>.from(payload['config'] as Map),
        'enabled': payload['enabled'] ?? true,
        'description': payload['description'] ?? '',
      },
    );

    await skillRegistry!.installSkill(meta);
    _log.info('Skill installed via sys command: $skillId');

    return AtRpcResp(
      reqId: reqId,
      respType: AtRpcRespType.success,
      payload: {
        'success': true,
        'response': 'Skill "$skillId" installed successfully.',
        'conversationId': 'sys',
      },
    );
  }

  Future<AtRpcResp> _sysSkillUninstall(
    Map<String, dynamic> payload,
    int reqId,
  ) async {
    final skillId = payload['skillId'] as String? ?? '';
    if (skillId.isEmpty) {
      return _errorResponse(reqId, 'skillId is required');
    }

    await skillRegistry!.removeSkill(skillId);
    _log.info('Skill removed via sys command: $skillId');

    return AtRpcResp(
      reqId: reqId,
      respType: AtRpcRespType.success,
      payload: {
        'success': true,
        'response': 'Skill "$skillId" removed.',
        'conversationId': 'sys',
      },
    );
  }

  Future<AtRpcResp> _sysSkillList(int reqId) async {
    final skills = await skillRegistry!.listInstalledSkills();
    final list = skills.map((s) => s.toJson()).toList();

    return AtRpcResp(
      reqId: reqId,
      respType: AtRpcRespType.success,
      payload: {
        'success': true,
        'response': jsonEncode(list),
        'conversationId': 'sys',
        'skills': list,
      },
    );
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
