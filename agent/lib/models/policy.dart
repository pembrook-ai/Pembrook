/// Policy models for Pembrook.
///
/// Policies are stored on @agent's atServer as:
///   policy.$policyId.pembrook@agent
///
/// The owner writes policies via the Flutter app policy editor.
/// They are serialized as JSON (with a YAML source for human editing).
///
/// Policy types:
///   identity   — which atSigns can send commands, and their roles
///   capability — per-skill / per-MCP-server permission sets
///   temporal   — time-based access windows
///   risk       — HITL thresholds per action category
///   dataFlow   — privacy classification per namespace
///   rateLimit  — max actions per time window

// ── Policy Decision ───────────────────────────────────────────────────────

/// Outcome of a policy evaluation.
class PolicyDecision {
  final bool allowed;
  final bool requiresHitl;
  final String reason;

  const PolicyDecision.allow({this.requiresHitl = false})
      : allowed = true,
        reason = 'Policy allowed';

  const PolicyDecision.deny(this.reason)
      : allowed = false,
        requiresHitl = false;

  const PolicyDecision.escalate(this.reason)
      : allowed = true,
        requiresHitl = true;

  /// True when the decision is an outright denial (not allowed, not HITL).
  bool get isDenied => !allowed && !requiresHitl;
}

// ── Policy Check Request ──────────────────────────────────────────────────

/// Input to PolicyEngine.checkPolicy()
///
/// Unified request that satisfies both gateway callers (senderAtSign / action)
/// and service-layer callers (initiatorAtSign / actionType / targetResource).
class PolicyCheckRequest {
  /// The atSign that initiated the action.
  /// Alias: some callers use [senderAtSign] — same field.
  final String initiatorAtSign;

  /// Brief action category, e.g. 'chat_command', 'skill.invoke', 'mcp.toolCall'
  final String actionType;

  /// Opaque payload (for risk scoring)
  final Map<String, dynamic> payload;

  /// Conversation context identifier
  final String conversationId;

  /// Target resource (skill ID, MCP tool path, 'gateway', etc.)
  final String? targetResource;

  /// The platform originating the command ('app', 'whatsapp', 'telegram', etc.)
  final String? platform;

  /// Skill being invoked (if applicable)
  final String? skillId;

  /// MCP server atSign being called (if applicable)
  final String? mcpServerAtSign;

  PolicyCheckRequest({
    // Primary field names used by service layer callers:
    String? initiatorAtSign,
    String? actionType,
    // Legacy alias fields used by gateway_callbacks:
    String? senderAtSign,
    String? action,
    this.payload = const {},
    this.conversationId = '',
    this.targetResource,
    this.platform,
    this.skillId,
    this.mcpServerAtSign,
    // Ignored legacy fields (kept for source compat without breaking):
    String? effectiveOwnerAtSign,
    String? command,
  })  : initiatorAtSign = initiatorAtSign ?? senderAtSign ?? '@unknown',
        actionType = actionType ?? action ?? 'unknown';
}

// ── Policy Rule ───────────────────────────────────────────────────────────

/// Decision an individual policy rule can make.
enum PolicyRuleAction { allow, deny, escalate }

/// A single rule within a policy.
class PolicyRule {
  final String ruleId;
  final String description;
  final PolicyRuleAction action;

  /// JSON-representable condition map (evaluated in PolicyEngine)
  final Map<String, dynamic> condition;

  const PolicyRule({
    required this.ruleId,
    required this.description,
    required this.action,
    required this.condition,
  });

  Map<String, dynamic> toJson() => {
        'ruleId': ruleId,
        'description': description,
        'action': action.name,
        'condition': condition,
      };

  factory PolicyRule.fromJson(Map<String, dynamic> json) => PolicyRule(
        ruleId: json['ruleId'] as String,
        description: json['description'] as String,
        action:
            PolicyRuleAction.values.byName(json['action'] as String? ?? 'deny'),
        condition: json['condition'] as Map<String, dynamic>? ?? {},
      );
}

// ── Policy ────────────────────────────────────────────────────────────────

enum PolicyType {
  identity,
  capability,
  temporal,
  risk,
  dataFlow,
  rateLimit,
}

/// A complete policy definition stored as an AtKey.
class Policy {
  final String policyId;
  final PolicyType policyType;
  final List<PolicyRule> rules;
  final int priority; // lower = evaluated first
  final String createdBy;
  final DateTime updatedAt;

  const Policy({
    required this.policyId,
    required this.policyType,
    required this.rules,
    required this.priority,
    required this.createdBy,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'policyId': policyId,
        'policyType': policyType.name,
        'rules': rules.map((r) => r.toJson()).toList(),
        'priority': priority,
        'createdBy': createdBy,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Policy.fromJson(Map<String, dynamic> json) => Policy(
        policyId: json['policyId'] as String,
        policyType: PolicyType.values
            .byName(json['policyType'] as String? ?? 'identity'),
        rules: (json['rules'] as List<dynamic>? ?? [])
            .map((r) => PolicyRule.fromJson(r as Map<String, dynamic>))
            .toList(),
        priority: json['priority'] as int? ?? 100,
        createdBy: json['createdBy'] as String? ?? '@owner',
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

// ── HITL models ───────────────────────────────────────────────────────────

/// A HITL approval request stored as AtKey: hitl.pending.$actionId.pembrook@agent
class HitlRequest {
  final String actionId;
  final String actionType;
  final String description;
  final Map<String, dynamic> payload;
  final String requesterAtSign;
  final DateTime createdAt;
  final int timeoutSeconds;
  final List<String> options;

  HitlRequest({
    required this.actionId,
    required this.actionType,
    required this.description,
    this.payload = const {},
    required this.requesterAtSign,
    DateTime? createdAt,
    this.timeoutSeconds = 300,
    this.options = const ['approve', 'deny'],
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  Map<String, dynamic> toJson() => {
        'actionId': actionId,
        'actionType': actionType,
        'description': description,
        'payload': payload,
        'requesterAtSign': requesterAtSign,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'timeoutSeconds': timeoutSeconds,
        'options': options,
      };

  factory HitlRequest.fromJson(Map<String, dynamic> json) => HitlRequest(
        actionId: json['actionId'] as String,
        actionType: json['actionType'] as String,
        description: json['description'] as String,
        payload: json['payload'] as Map<String, dynamic>? ?? {},
        requesterAtSign: json['requesterAtSign'] as String? ?? '@unknown',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
        timeoutSeconds: json['timeoutSeconds'] as int? ?? 300,
        options: (json['options'] as List<dynamic>? ?? ['approve', 'deny'])
            .cast<String>(),
      );
}

/// The owner's response to a HITL request.
class HitlDecision {
  final bool approved;
  final Map<String, dynamic>? modifiedParams;
  final String? reason;

  const HitlDecision({
    required this.approved,
    this.modifiedParams,
    this.reason,
  });
}
