/// TaskScheduler — persist and execute scheduled tasks as AtKeys.
///
/// KEY PATTERN:
///   schedule.$taskId.safeclaw@agent  →  JSON-encoded TaskDefinition
///   taskrun.$taskId.$ts.safeclaw@agent → JSON run-history entry (TTL 90 d)
///
/// All reads/writes use useRemoteAtServer = true.
///
/// CRON / ONE-SHOT:
///   - If TaskDefinition.cronExpression is set, the task repeats.
///   - If TaskDefinition.runAt is set (and no cron), it runs once and is deleted.
///
/// The HeartbeatEngine calls TaskScheduler.tick() every minute.

import 'dart:async';
import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:cron/cron.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../models/task.dart';
import '../core/policy_engine.dart';
import '../core/hitl_manager.dart';
import '../services/audit_service.dart';
import '../models/audit_entry.dart';
import '../models/policy.dart';

class TaskScheduler {
  final AtClient atClient;
  final PolicyEngine policyEngine;
  final HitlManager hitlManager;
  final AuditService auditService;
  final Logger _log = Logger('TaskScheduler');
  final Uuid _uuid = const Uuid();

  static const String _namespace = 'safeclaw';
  static const int _runHistoryTtlMs = 90 * 24 * 60 * 60 * 1000; // 90 days

  TaskScheduler({
    required this.atClient,
    required this.policyEngine,
    required this.hitlManager,
    required this.auditService,
  });

  // ──────────────────────────────────────────────────────────
  //  CRUD
  // ──────────────────────────────────────────────────────────

  Future<TaskDefinition> scheduleTask(TaskDefinition task) async {
    final atKey = _taskKey(task.taskId);
    await atClient.put(
      atKey,
      jsonEncode(task.toJson()),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
    _log.info(
        'Task scheduled: ${task.taskId} (${task.cronExpression ?? task.runAt})');
    return task;
  }

  Future<void> cancelTask(String taskId) async {
    await atClient.delete(_taskKey(taskId));
    _log.info('Task cancelled: $taskId');
  }

  Future<List<TaskDefinition>> listTasks() async {
    try {
      final keys = await atClient.getKeys(regex: r'^schedule\.');
      final tasks = <TaskDefinition>[];
      for (final keyStr in keys) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await atClient.get(atKey,
              getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
          if (v.value != null) {
            tasks.add(TaskDefinition.fromJson(
                jsonDecode(v.value as String) as Map<String, dynamic>));
          }
        } catch (_) {}
      }
      return tasks;
    } catch (e) {
      _log.warning('listTasks error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────
  //  TICK (called by HeartbeatEngine every minute)
  // ──────────────────────────────────────────────────────────

  Future<void> tick() async {
    final now = DateTime.now().toUtc();
    final tasks = await listTasks();

    for (final task in tasks) {
      final shouldRun = _shouldRunNow(task, now);
      if (!shouldRun) continue;

      // Remove one-shot tasks before running to prevent double execution.
      if (task.cronExpression == null) {
        await cancelTask(task.taskId);
      }

      unawaited(_executeTask(task));
    }
  }

  // ──────────────────────────────────────────────────────────
  //  EXECUTION
  // ──────────────────────────────────────────────────────────

  Future<void> _executeTask(TaskDefinition task) async {
    // Policy check
    final policyReq = PolicyCheckRequest(
      initiatorAtSign: atClient.getCurrentAtSign() ?? '@agent',
      targetResource: 'task:${task.taskId}',
      actionType: 'task.run',
      payload: task.toJson(),
      conversationId: 'scheduled',
    );
    final decision = await policyEngine.checkPolicy(policyReq);

    if (decision.isDenied) {
      _log.warning('Task ${task.taskId} denied by policy: ${decision.reason}');
      await _logRun(task.taskId, 'denied', decision.reason);
      return;
    }

    if (decision.requiresHitl || task.hitlRequired) {
      final hitlReq = HitlRequest(
        actionId: 'task_${task.taskId}',
        actionType: 'task.run',
        description: 'Scheduled task "${task.taskId}" is about to run',
        payload: task.toJson(),
        requesterAtSign: atClient.getCurrentAtSign() ?? '@agent',
      );
      final hitlDecision = await hitlManager.requestApproval(hitlReq);
      if (!hitlDecision.approved) {
        _log.info('Task ${task.taskId} HITL denied');
        await _logRun(task.taskId, 'hitl_denied', hitlDecision.reason);
        return;
      }
    }

    _log.info('Executing task: ${task.taskId}');
    // Phase 4: wire to SkillRunner / SecureMcpClient based on task.skillToInvoke
    // For now, record a stub run.
    await _logRun(task.taskId, 'executed', null);

    await auditService.log(AuditEntry(
      timestamp: DateTime.now().toUtc(),
      actionType: 'task.run.${task.taskId}',
      initiatorAtSign: atClient.getCurrentAtSign() ?? '@agent',
      targetResource: 'task:${task.taskId}',
      policyDecision: 'allowed',
    ));
  }

  Future<void> _logRun(String taskId, String status, String? notes) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final atKey = AtKey()
      ..key = 'taskrun.$taskId.$ts'
      ..namespace = _namespace
      ..sharedWith = atClient.getCurrentAtSign()
      ..metadata = (Metadata()
        ..ttl = _runHistoryTtlMs
        ..ttr = -1);
    await atClient.put(
      atKey,
      jsonEncode({'status': status, 'notes': notes, 'ts': ts}),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
  }

  // ──────────────────────────────────────────────────────────
  //  HELPERS
  // ──────────────────────────────────────────────────────────

  AtKey _taskKey(String taskId) => AtKey()
    ..key = 'schedule.$taskId'
    ..namespace = _namespace
    ..sharedWith = atClient.getCurrentAtSign()
    ..metadata = (Metadata()
      ..ttl = 0
      ..ttr = -1);

  bool _shouldRunNow(TaskDefinition task, DateTime now) {
    if (task.cronExpression != null) {
      return _matchesCron(task.cronExpression!, now);
    }
    if (task.runAt != null) {
      // Run if within a 1-minute window
      final diff = now.difference(task.runAt!).abs();
      return diff.inSeconds < 60;
    }
    return false;
  }

  bool _matchesCron(String expression, DateTime now) {
    try {
      final schedule = Schedule.parse(expression);
      return schedule.shouldRunAt(now);
    } catch (_) {
      return false;
    }
  }
}
