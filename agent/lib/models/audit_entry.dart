/// Audit entry model.
///
/// Audit entries are stored on @owner's atServer (NOT @agent's) so the agent
/// cannot delete its own logs. They use Metadata()..immutable = true so they
/// cannot be modified after creation.
///
/// AtKey pattern: audit.$timestamp.$actionId.pembrook@owner
/// Key belongs to @owner — @agent writes via sharedWith, owner reads all.

/// Policy decision outcomes.
enum PolicyDecisionStatus { allowed, denied, escalated }

class AuditEntry {
  /// Unix milliseconds
  final DateTime timestamp;

  /// Human-readable action category: 'command', 'skill_invocation',
  /// 'mcp_tool_call', 'hitl_request', 'policy_violation', 'rate_limit_exceeded'
  final String actionType;

  /// atSign that originated the action
  final String initiatorAtSign;

  /// Target resource (key name, skill ID, MCP tool, etc.)
  final String? targetResource;

  /// Result of policy evaluation
  final String policyDecision; // 'allowed' | 'denied' | 'escalated'

  /// SHA-256 (or simplified hash) of the input for audit trail integrity
  final String? inputHash;

  /// SHA-256 of the output (set after execution)
  final String? outputHash;

  /// Wall-clock execution time in milliseconds
  final int? executionDurationMs;

  /// If a skill was involved, its skill ID
  final String? skillId;

  /// If an MCP server was involved, its atSign
  final String? mcpServer;

  /// Free-form notes (e.g. denial reason)
  final String? notes;

  AuditEntry({
    DateTime? timestamp,
    required this.actionType,
    required this.initiatorAtSign,
    this.targetResource,
    required this.policyDecision,
    this.inputHash,
    this.outputHash,
    this.executionDurationMs,
    this.skillId,
    this.mcpServer,
    this.notes,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.millisecondsSinceEpoch,
        'actionType': actionType,
        'initiatorAtSign': initiatorAtSign,
        if (targetResource != null) 'targetResource': targetResource,
        'policyDecision': policyDecision,
        if (inputHash != null) 'inputHash': inputHash,
        if (outputHash != null) 'outputHash': outputHash,
        if (executionDurationMs != null)
          'executionDurationMs': executionDurationMs,
        if (skillId != null) 'skillId': skillId,
        if (mcpServer != null) 'mcpServer': mcpServer,
        if (notes != null) 'notes': notes,
      };

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
        timestamp:
            DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
        actionType: json['actionType'] as String,
        initiatorAtSign: json['initiatorAtSign'] as String,
        targetResource: json['targetResource'] as String?,
        policyDecision: json['policyDecision'] as String,
        inputHash: json['inputHash'] as String?,
        outputHash: json['outputHash'] as String?,
        executionDurationMs: json['executionDurationMs'] as int?,
        skillId: json['skillId'] as String?,
        mcpServer: json['mcpServer'] as String?,
        notes: json['notes'] as String?,
      );
}
