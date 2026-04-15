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
import 'dart:io';
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
  final AtClient atClient;

  /// Optional skill registry — required for _sys.skill.* management commands.
  final SkillRegistry? skillRegistry;

  final Logger _log = Logger('GatewayCallbacks');
  final Uuid _uuid = const Uuid();

  // SEC-007: Rate limit tracker persisted to AtKeys so counters survive restarts.
  // In-memory copy kept for speed; AtKey used as durable backing store.
  final Map<String, List<DateTime>> _rateLimitTracker = {};

  GatewayCallbacks({
    required this.orchestrator,
    required this.policyEngine,
    required this.auditService,
    required this.atClient,
    this.skillRegistry,
  });

  /// SEC-007: Load persisted rate-limit counters from AtKeys on startup.
  /// Call this once after construction before accepting requests.
  Future<void> loadPersistedRateLimits() async {
    try {
      final agentAtSign = atClient.getCurrentAtSign() ?? '';
      final key = AtKey()
        ..key = 'ratelimit.counters.pembrook'
        ..sharedBy = agentAtSign;
      final result = await atClient.get(key,
          getRequestOptions: GetRequestOptions()..useRemoteAtServer = false);
      if (result.value is String && (result.value as String).isNotEmpty) {
        final raw = jsonDecode(result.value as String) as Map<String, dynamic>;
        final windowStart = DateTime.now().subtract(kRateLimitWindow);
        raw.forEach((atSign, timestamps) {
          final times = (timestamps as List<dynamic>)
              .map((ms) => DateTime.fromMillisecondsSinceEpoch(ms as int))
              .where((t) => t.isAfter(windowStart))
              .toList();
          if (times.isNotEmpty) _rateLimitTracker[atSign] = times;
        });
        _log.info(
            'Loaded rate-limit state for ${_rateLimitTracker.length} atSign(s)');
      }
    } catch (e) {
      // Non-fatal — start with empty counters rather than blocking startup.
      _log.warning('Could not load persisted rate-limit state: $e');
    }
  }

  /// SEC-007: Persist current rate-limit counters to a local AtKey.
  Future<void> _persistRateLimits() async {
    try {
      final agentAtSign = atClient.getCurrentAtSign() ?? '';
      final now = DateTime.now();
      final windowStart = now.subtract(kRateLimitWindow);
      // Only persist live (in-window) entries.
      final live = <String, List<int>>{};
      _rateLimitTracker.forEach((atSign, times) {
        final inWindow = times
            .where((t) => t.isAfter(windowStart))
            .map((t) => t.millisecondsSinceEpoch)
            .toList();
        if (inWindow.isNotEmpty) live[atSign] = inWindow;
      });
      final key = AtKey()
        ..key = 'ratelimit.counters.pembrook'
        ..sharedBy = agentAtSign
        ..metadata = (Metadata()..ttl = kRateLimitWindow.inMilliseconds);
      await atClient.put(key, jsonEncode(live));
    } catch (e) {
      _log.warning('Could not persist rate-limit state: $e');
    }
  }

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
      // For bridge messages, senderAtSign in the payload carries the claimed
      // user identity. SEC-009: only honour this override when the
      // transport-verified sender IS the registered owner — preventing a
      // compromised bridge/service from escalating to owner privileges.
      final effectiveSender = _resolveEffectiveSender(
        fromAtSign: fromAtSign,
        payloadSenderAtSign: payload['senderAtSign'] as String?,
      );
      final platform = payload['platform'] as String? ?? 'app';
      final streamingEnabled = payload['streamingEnabled'] as bool? ?? true;
      // Owner's local timezone string sent by the app, e.g. "UTC-07:00 (PDT)".
      // Passed to the LLM so it can correctly interpret wall-clock times.
      final userTimezone = payload['userTimezone'] as String? ?? '';

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
        streamingEnabled: streamingEnabled,
        userTimezone: userTimezone,
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
      // I2: return generic message — full detail is in the log, not exposed to caller.
      return _errorResponse(request.reqId, 'An internal error occurred.');
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
      return _errorResponse(
          reqId, 'SkillRegistry not wired — cannot manage skills');
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
      // I2: return generic message — detail stays in log only.
      return _errorResponse(reqId, 'System command failed.');
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
    // Known network-requiring skills always get bridge networking regardless
    // of whether the toggle was set in the app.
    const _networkSkills = {'email', 'calendar', 'web_search'};
    final requiresNetwork = (payload['requiresNetwork'] as bool? ?? false) ||
        _networkSkills.contains(skillId);

    final meta = SkillMetadata(
      skillId: skillId,
      skillAtSign: payload['skillAtSign'] as String? ?? fromAtSign,
      developerAtSign:
          fromAtSign, // owner is the "developer" for app-registered skills
      signatureHash: 'app-registered-${_uuid.v4()}',
      version: payload['version'] as String? ?? '1.0.0',
      declaredCapabilities: SkillCapabilities(
        // M4: Grant named endpoint categories instead of a wildcard ['*'].
        // The actual network isolation is enforced by Docker (pembrook_skill_net
        // has no access to internal services). These labels exist for audit
        // trail and policy-engine filtering, not as trusted allow-lists.
        networkEndpoints: requiresNetwork
            ? switch (skillId) {
                'email' => const ['smtp', 'imap'],
                'calendar' => const ['caldav', 'https'],
                'web_search' => const ['https'],
                _ => const ['https'], // safe default for unknown network skills
              }
            : const [],
      ),
      trustScore: (payload['trustScore'] as num?)?.toDouble() ?? 0.5,
      installedAt: DateTime.now().toUtc(),
      lastAuditResult: 'app-registered',
      ownerPolicyOverrides: {
        'enabled': payload['enabled'] ?? true,
        'description': payload['description'] ?? '',
      },
      // Credentials stored encrypted on @owner's atServer; injected at invocation.
      config: (payload['config'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v.toString())),
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
    // SEC-007: Persist asynchronously — don't await to keep the hot path fast.
    _persistRateLimits();
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

  /// SEC-009: Resolve the effective sender identity safely.
  ///
  /// Bridges embed a `senderAtSign` in their payload to relay the real end-user
  /// identity. We ONLY trust this override when the transport-authenticated
  /// `fromAtSign` is the registered owner — no bridge or service identity may
  /// claim to be the owner through a payload field.
  String _resolveEffectiveSender({
    required String fromAtSign,
    required String? payloadSenderAtSign,
  }) {
    if (payloadSenderAtSign == null || payloadSenderAtSign == fromAtSign) {
      return fromAtSign;
    }
    final ownerAtSign = Platform.environment['OWNER_AT_SIGN'] ?? '';
    if (ownerAtSign.isNotEmpty && fromAtSign == ownerAtSign) {
      // The authenticated sender is the owner — trust the embedded identity.
      return payloadSenderAtSign;
    }
    // Bridge/service identity attempted to claim a different atSign.
    // Discard the payload field and use the transport-verified identity.
    _log.warning(
      'SEC-009: Rejected senderAtSign override from $fromAtSign '
      '(claimed: $payloadSenderAtSign) — using transport identity.',
    );
    return fromAtSign;
  }

  String _hash(String value) {
    return AuditService.contentHash(value);
  }
}
