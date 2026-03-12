/// HeartbeatEngine — periodic agent maintenance loop.
///
/// Runs every minute (configurable) and does:
///   1. Tick the TaskScheduler (run due tasks).
///   2. Health check: write heart.beat.safeclaw@agent (TTL 2 min) so
///      @owner can tell the agent is alive.
///   3. Memory maintenance: call MemoryService.summarizeOldConversations().
///   4. Owner-configured proactive checks (loaded from AtKey):
///      "proactive_checks.safeclaw@agent" → JSON list of check configs.
///
/// The heartbeat AtKey uses a short TTL so it auto-expires when the
/// agent goes offline — @owner can watch for absence.

import 'dart:async';
import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import 'scheduler.dart';
import 'notification_manager.dart';
import '../services/memory_service.dart';
import '../models/task.dart';

class HeartbeatEngine {
  final AtClient atClient;
  final TaskScheduler scheduler;
  final NotificationManager notificationManager;
  final MemoryService memoryService;
  final Logger _log = Logger('HeartbeatEngine');

  static const String _namespace = 'safeclaw';
  static const Duration _interval = Duration(minutes: 1);
  // Heartbeat key TTL: 2 minutes — auto-expires if agent goes offline.
  static const int _heartbeatTtlMs = 120000;

  Timer? _timer;
  bool _running = false;

  HeartbeatEngine({
    required this.atClient,
    required this.scheduler,
    required this.notificationManager,
    required this.memoryService,
  });

  void start() {
    if (_running) return;
    _running = true;
    _log.info('HeartbeatEngine started (interval=${_interval.inSeconds}s)');
    _timer = Timer.periodic(_interval, (_) => _tick());
    // Run immediately on start.
    _tick();
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _log.info('HeartbeatEngine stopped');
  }

  // ──────────────────────────────────────────────────────────
  //  TICK
  // ──────────────────────────────────────────────────────────

  Future<void> _tick() async {
    try {
      await Future.wait([
        _writeHeartbeat(),
        scheduler.tick(),
      ]);
      await _performProactiveChecks();
      await memoryService.summarizeOldConversations();
    } catch (e) {
      _log.warning('HeartbeatEngine tick error: $e');
    }
  }

  // ──────────────────────────────────────────────────────────
  //  HEARTBEAT KEY
  // ──────────────────────────────────────────────────────────

  Future<void> _writeHeartbeat() async {
    final key = AtKey()
      ..key = 'heart.beat'
      ..namespace = _namespace
      ..sharedWith = atClient.getCurrentAtSign()
      ..metadata = (Metadata()
        ..ttl = _heartbeatTtlMs
        ..ttr = -1);

    await atClient.put(
      key,
      jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'version': '1.0.0',
      }),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
  }

  // ──────────────────────────────────────────────────────────
  //  PROACTIVE CHECKS
  // ──────────────────────────────────────────────────────────

  Future<void> _performProactiveChecks() async {
    final configKey = AtKey()
      ..key = 'proactive_checks'
      ..namespace = _namespace
      ..sharedWith = atClient.getCurrentAtSign();

    try {
      final result = await atClient.get(
        configKey,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (result.value == null) return;

      final checks = jsonDecode(result.value as String) as List<dynamic>;

      for (final check in checks) {
        await _runProactiveCheck(check as Map<String, dynamic>);
      }
    } catch (_) {
      // No checks configured or parse error — silently skip.
    }
  }

  Future<void> _runProactiveCheck(Map<String, dynamic> check) async {
    final type = check['type'] as String?;
    final threshold = check['threshold'];

    if (type == null) return;

    // Example: {"type": "disk_check", "threshold": 90}
    // Phase 5: implement actual check logic via skill/MCP calls.
    _log.fine('Proactive check: $type (threshold=$threshold)');
  }
}
