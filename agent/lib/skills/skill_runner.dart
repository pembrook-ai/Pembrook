/// SkillRunner — orchestrates the full lifecycle of a skill invocation.
///
/// FLOW:
///   1. Look up SkillMetadata in registry (trust score, capabilities).
///   2. Do a policy check for the requested capabilities.
///   3. If HITL is required, block until approval (or timeout → deny).
///   4. Run the skill in SandboxManager.
///   5. Log audit entry.
///   6. Return the SandboxResult.
///
/// Skills that require network access (networkEndpoints not empty) are
/// denied at step 2 because --network=none is hard-coded in SandboxManager.
/// Future: allow-list specific endpoints via a sidecar proxy.

import 'package:logging/logging.dart';

import '../models/audit_entry.dart';
import '../models/policy.dart';
import '../core/policy_engine.dart';
import '../core/hitl_manager.dart';
import '../services/audit_service.dart';
import 'registry.dart';
import 'sandbox_manager.dart';

class SkillRunResult {
  final bool success;
  final Map<String, dynamic>? result;
  final String? error;
  final String? denialReason;

  const SkillRunResult({
    required this.success,
    this.result,
    this.error,
    this.denialReason,
  });
}

class SkillRunner {
  final SkillRegistry registry;
  final SandboxManager sandboxManager;
  final PolicyEngine policyEngine;
  final HitlManager hitlManager;
  final AuditService auditService;
  final Logger _log = Logger('SkillRunner');

  SkillRunner({
    required this.registry,
    required this.sandboxManager,
    required this.policyEngine,
    required this.hitlManager,
    required this.auditService,
  });

  Future<SkillRunResult> invoke({
    required String skillId,
    required String initiatorAtSign,
    required Map<String, dynamic> payload,
    String? conversationId,
  }) async {
    // ── 1. Registry lookup ───────────────────────────────────
    final meta = await registry.getSkill(skillId);
    if (meta == null) {
      _log.warning('Skill not found: $skillId');
      return const SkillRunResult(
        success: false,
        denialReason: 'Skill not installed',
      );
    }

    // ── 2. Policy check ──────────────────────────────────────
    final policyReq = PolicyCheckRequest(
      initiatorAtSign: initiatorAtSign,
      targetResource: 'skill:$skillId',
      actionType: 'skill.invoke',
      payload: payload,
      conversationId: conversationId ?? '',
    );
    final decision = await policyEngine.checkPolicy(policyReq);

    if (decision.isDenied) {
      await _audit(
        actionType: 'skill.invoke.$skillId',
        initiatorAtSign: initiatorAtSign,
        policyDecision: 'denied',
        notes: decision.reason,
      );
      return SkillRunResult(
        success: false,
        denialReason: decision.reason ?? 'Policy denied',
      );
    }

    // ── 3. HITL if required (policy escalation OR skill demands it) ───
    final needsHitl = decision.requiresHitl ||
        meta.declaredCapabilities.hitlRequired.isNotEmpty;

    if (needsHitl) {
      final hitlReq = HitlRequest(
        actionId: 'skill_$skillId',
        actionType: 'skill.invoke',
        description: 'Skill "$skillId" invoked by $initiatorAtSign',
        payload: payload,
        requesterAtSign: initiatorAtSign,
      );
      final hitlDecision = await hitlManager.requestApproval(hitlReq);
      if (!hitlDecision.approved) {
        await _audit(
          actionType: 'skill.invoke.$skillId',
          initiatorAtSign: initiatorAtSign,
          policyDecision: 'denied',
          notes: 'HITL: ${hitlDecision.reason ?? "not approved"}',
        );
        return SkillRunResult(
          success: false,
          denialReason: 'HITL approval denied: ${hitlDecision.reason ?? ""}',
        );
      }
    }

    // ── 4. Execute in sandbox ────────────────────────────────
    _log.info('Running skill: $skillId for $initiatorAtSign');

    // Merge stored config as defaults — LLM-provided payload values win.
    // Config holds credentials (smtpHost, smtpPassword, accessToken, etc.)
    // that were saved by the owner in the Skills config screen.
    final mergedPayload = <String, dynamic>{...meta.config, ...payload};

    final sandboxResult = await sandboxManager.run(meta, mergedPayload);

    // ── 5. Audit ─────────────────────────────────────────────
    await _audit(
      actionType: 'skill.invoke.$skillId',
      initiatorAtSign: initiatorAtSign,
      policyDecision: sandboxResult.success ? 'allowed' : 'denied',
      skillId: skillId,
      executionDurationMs: sandboxResult.duration.inMilliseconds,
      notes: sandboxResult.error,
    );

    return SkillRunResult(
      success: sandboxResult.success,
      result: sandboxResult.result,
      error: sandboxResult.error,
    );
  }

  Future<void> _audit({
    required String actionType,
    required String initiatorAtSign,
    required String policyDecision,
    String? skillId,
    int? executionDurationMs,
    String? notes,
  }) async {
    await auditService.log(AuditEntry(
      timestamp: DateTime.now().toUtc(),
      actionType: actionType,
      initiatorAtSign: initiatorAtSign,
      targetResource: skillId != null ? 'skill:$skillId' : null,
      policyDecision: policyDecision,
      skillId: skillId,
      executionDurationMs: executionDurationMs,
      notes: notes,
    ));
  }
}
