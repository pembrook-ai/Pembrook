/// PolicyEngine — consulted before EVERY agent action.
///
/// All checks happen synchronously before execution proceeds.
/// The engine evaluates policies in priority order (lowest number first).
/// The first matching policy rule wins.
///
/// Default behavior when no policies are loaded (Phase 1 operation):
///   All actions from @owner are allowed.
///   All actions from @bridge_* are allowed.
///   Everything else is denied.
///
/// Policies are stored as AtKeys:
///   policy.$policyId.pembrook@agent
///
/// Owner writes policies via the Flutter app and they sync automatically
/// across all devices and to the agent's atServer.

import 'dart:convert';
import 'dart:io';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../models/policy.dart';

class PolicyEngine {
  final AtClient atClient;
  final Logger _log = Logger('PolicyEngine');

  // In-memory cache of loaded policies, refreshed periodically
  final List<Policy> _cachedPolicies = [];
  DateTime _lastPolicyRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _policyCacheTtl = Duration(minutes: 5);

  // Full allow list — mirrors Gateway's allow list.
  // Loaded from AtKeys + env vars (OWNER_AT_SIGN, ALLOWED_USERS) as fallback.
  // Refreshed every 5 minutes.
  final Set<String> _allowList = {};
  DateTime _ownerAtSignLastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _ownerAtSignCacheTtl = Duration(minutes: 5);

  PolicyEngine({required this.atClient});

  /// Evaluate whether the given action should be allowed, denied, or escalated.
  ///
  /// Evaluated policy types (in order):
  ///   1. Identity  — is the sender authorized?
  ///   2. Capability — is the action within the sender's permitted scope?
  ///   3. Temporal   — is the action allowed at this time?
  ///   4. Risk       — does this action category require HITL?
  ///   5. Data flow  — can this data leave the local system?
  ///   6. Rate limit — handled in Gateway; this level is a double-check
  Future<PolicyDecision> checkPolicy(PolicyCheckRequest request) async {
    await _maybeRefreshOwnerAtSign();
    await _maybeRefreshPolicies();

    // ── Identity check ────────────────────────────────────────────────────
    // Phase 1 baseline: only @owner and @bridge_* are trusted.
    // Later phases load dynamic policies from AtKeys.
    if (!_isIdentityAllowed(request.initiatorAtSign)) {
      _log.warning('Identity check failed for ${request.initiatorAtSign}');
      return const PolicyDecision.deny('Sender not in identity allow list');
    }

    // ── Dynamic policy evaluation ─────────────────────────────────────────
    for (final policy in _cachedPolicies
      ..sort((a, b) => a.priority.compareTo(b.priority))) {
      final decision = _evaluatePolicy(policy, request);
      if (decision != null) {
        _log.fine(
            'Policy ${policy.policyId} matched: ${decision.allowed ? "allow" : "deny"}');
        return decision;
      }
    }

    // ── Risk-based HITL escalation (default rules) ────────────────────────
    if (_isHighRiskAction(request.actionType)) {
      _log.info('High-risk action escalated to HITL: ${request.actionType}');
      return PolicyDecision.escalate(
          'Action category "${request.actionType}" requires owner approval');
    }

    // Default: allow (policies are additive deny/escalate rules)
    return const PolicyDecision.allow();
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  bool _isIdentityAllowed(String atSign) {
    if (_allowList.contains(atSign)) return true;
    if (atSign.startsWith('@bridge_')) return true;
    if (atSign.startsWith('@skill_')) return true;
    if (atSign.startsWith('@mcp_')) return true;
    return false;
  }

  /// Phase 1 default: flag high-risk action categories for HITL.
  bool _isHighRiskAction(String action) {
    const hitlActions = {
      'send_email',
      'purchase',
      'transfer_money',
      'delete_file',
      'execute_shell',
      'post_social_media',
      'lock_door',
      'camera_snapshot',
    };
    return hitlActions.contains(action);
  }

  PolicyDecision? _evaluatePolicy(Policy policy, PolicyCheckRequest request) {
    for (final rule in policy.rules) {
      if (_ruleMatches(rule, policy.policyType, request)) {
        switch (rule.action) {
          case PolicyRuleAction.allow:
            return const PolicyDecision.allow();
          case PolicyRuleAction.deny:
            return PolicyDecision.deny(rule.description);
          case PolicyRuleAction.escalate:
            return PolicyDecision.escalate(rule.description);
        }
      }
    }
    return null; // policy did not match — continue to next
  }

  bool _ruleMatches(
      PolicyRule rule, PolicyType type, PolicyCheckRequest request) {
    final cond = rule.condition;
    // Temporal check
    if (type == PolicyType.temporal) {
      final hour = DateTime.now().hour;
      final afterHour = cond['afterHour'] as int?;
      final beforeHour = cond['beforeHour'] as int?;
      if (afterHour != null && hour >= afterHour) return true;
      if (beforeHour != null && hour < beforeHour) return true;
    }
    // Action match
    if (cond['action'] != null && cond['action'] != request.actionType) {
      return false;
    }
    // Sender match
    if (cond['senderAtSign'] != null &&
        cond['senderAtSign'] != request.initiatorAtSign) {
      return false;
    }
    return cond.isNotEmpty;
  }

  /// Refresh the allow list from AtKeys + env vars (cached for 5 min).
  /// Mirrors the Gateway's _refreshAllowList logic so both are consistent.
  Future<void> _maybeRefreshOwnerAtSign() async {
    final now = DateTime.now();
    if (now.difference(_ownerAtSignLastRefresh) < _ownerAtSignCacheTtl) return;

    final fresh = <String>{};

    // 1. AtKey: settings.owner_atsign
    try {
      final ownerKey = AtKey()
        ..key = 'settings.owner_atsign'
        ..namespace = 'pembrook';
      final ownerVal = await atClient.get(
        ownerKey,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (ownerVal.value != null && (ownerVal.value as String).isNotEmpty) {
        fresh.add((ownerVal.value as String).trim());
      }
    } catch (_) {}

    // 2. AtKey: settings.allowed_users  (JSON array)
    try {
      final usersKey = AtKey()
        ..key = 'settings.allowed_users'
        ..namespace = 'pembrook';
      final usersVal = await atClient.get(
        usersKey,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (usersVal.value != null) {
        final list = jsonDecode(usersVal.value as String) as List<dynamic>;
        for (final s in list) {
          if (s is String && s.isNotEmpty) fresh.add(s.trim());
        }
      }
    } catch (_) {}

    // 3. Env var fallback: OWNER_AT_SIGN
    final envOwner = Platform.environment['OWNER_AT_SIGN'] ?? '';
    if (envOwner.isNotEmpty) fresh.add(envOwner.trim());

    // 4. Env var fallback: ALLOWED_USERS=@a,@b,@c
    final envUsers = Platform.environment['ALLOWED_USERS'] ?? '';
    for (final s in envUsers.split(',')) {
      final t = s.trim();
      if (t.isNotEmpty) fresh.add(t);
    }

    if (fresh.isEmpty) {
      // No config at all — keep the current list (safer than wiping it).
      _log.warning(
          'PolicyEngine: allow list sources empty; retaining current list: $_allowList');
    } else if (fresh != _allowList) {
      _log.info('PolicyEngine: allow list updated → $fresh');
      _allowList
        ..clear()
        ..addAll(fresh);
    }
    _ownerAtSignLastRefresh = now;
  }

  Future<void> _maybeRefreshPolicies() async {
    final now = DateTime.now();
    if (now.difference(_lastPolicyRefresh) < _policyCacheTtl) return;

    _log.fine('Refreshing policy cache from AtKeys');
    _cachedPolicies.clear();

    try {
      // List all policy keys: policy.*.pembrook@agent
      final keys = await atClient.getKeys(
        regex: r'^policy\.',
      );
      for (final keyStr in keys) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final atValue = await atClient.get(atKey);
          if (atValue.value != null) {
            final policy = Policy.fromJson(jsonDecode(atValue.value as String));
            _cachedPolicies.add(policy);
          }
        } catch (e) {
          _log.warning('Failed to load policy key $keyStr: $e');
        }
      }
      _lastPolicyRefresh = now;
      _log.info('Loaded ${_cachedPolicies.length} policies');
    } catch (e) {
      _log.warning('Policy refresh failed (using cached/defaults): $e');
    }
  }
}
