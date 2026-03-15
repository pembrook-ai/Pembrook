/// Task and Schedule models.
///
/// Scheduled tasks stored as AtKeys:
///   schedule.$taskId.pembrook@agent
///
/// All scheduled executions go through the same policy pipeline as
/// interactive commands — no bypass for automated/background actions.

/// Urgency level for notifications sent to the owner.
enum NotificationUrgency {
  /// Batched into daily digest
  low,

  /// Delivered immediately
  medium,

  /// Immediately + repeat until acknowledged
  high,

  /// All channels simultaneously (app + all bridges)
  critical,
}

/// A scheduled or one-shot task definition.
class TaskDefinition {
  final String taskId;

  /// Cron expression for recurring tasks, or null for one-shot
  /// Examples: '0 7 * * *' (every morning 7am), '*/10 * * * *' (every 10min)
  final String? cronExpression;

  /// ISO-8601 date-time for one-shot tasks
  final DateTime? runAt;

  /// Skill ID to invoke, or null for LLM-based automation
  final String? skillToInvoke;

  /// MCP server atSign to call, or null
  final String? mcpServerAtSign;

  /// MCP tool name, or null
  final String? mcpTool;

  /// Parameters to pass to the skill or MCP tool
  final Map<String, dynamic> parameters;

  /// Whether this task requires HITL approval before execution
  final bool hitlRequired;

  final int maxRetries;
  final String ownerAtSign;
  final DateTime createdAt;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;

  const TaskDefinition({
    required this.taskId,
    this.cronExpression,
    this.runAt,
    this.skillToInvoke,
    this.mcpServerAtSign,
    this.mcpTool,
    this.parameters = const {},
    this.hitlRequired = false,
    this.maxRetries = 3,
    required this.ownerAtSign,
    required this.createdAt,
    this.lastRunAt,
    this.nextRunAt,
  });

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        if (cronExpression != null) 'cronExpression': cronExpression,
        if (runAt != null) 'runAt': runAt!.toIso8601String(),
        if (skillToInvoke != null) 'skillToInvoke': skillToInvoke,
        if (mcpServerAtSign != null) 'mcpServerAtSign': mcpServerAtSign,
        if (mcpTool != null) 'mcpTool': mcpTool,
        'parameters': parameters,
        'hitlRequired': hitlRequired,
        'maxRetries': maxRetries,
        'ownerAtSign': ownerAtSign,
        'createdAt': createdAt.toIso8601String(),
        if (lastRunAt != null) 'lastRunAt': lastRunAt!.toIso8601String(),
        if (nextRunAt != null) 'nextRunAt': nextRunAt!.toIso8601String(),
      };

  factory TaskDefinition.fromJson(Map<String, dynamic> json) => TaskDefinition(
        taskId: json['taskId'] as String,
        cronExpression: json['cronExpression'] as String?,
        runAt: json['runAt'] != null
            ? DateTime.tryParse(json['runAt'] as String)
            : null,
        skillToInvoke: json['skillToInvoke'] as String?,
        mcpServerAtSign: json['mcpServerAtSign'] as String?,
        mcpTool: json['mcpTool'] as String?,
        parameters: json['parameters'] as Map<String, dynamic>? ?? {},
        hitlRequired: json['hitlRequired'] as bool? ?? false,
        maxRetries: json['maxRetries'] as int? ?? 3,
        ownerAtSign: json['ownerAtSign'] as String? ?? '@owner',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        lastRunAt: json['lastRunAt'] != null
            ? DateTime.tryParse(json['lastRunAt'] as String)
            : null,
        nextRunAt: json['nextRunAt'] != null
            ? DateTime.tryParse(json['nextRunAt'] as String)
            : null,
      );
}

/// An alert to send to the owner.
class Alert {
  final String alertId;
  final String title;
  final String message;
  final NotificationUrgency urgency;
  final Map<String, dynamic>? data;
  final DateTime createdAt;

  /// If true, bypass digest queue and send immediately even for medium/low urgency.
  final bool forceImmediate;

  Alert({
    required this.alertId,
    required this.title,
    required this.message,
    required this.urgency,
    this.data,
    this.forceImmediate = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'alertId': alertId,
        'title': title,
        'message': message,
        'urgency': urgency.name,
        if (data != null) 'data': data,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };
}
