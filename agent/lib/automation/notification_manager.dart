/// NotificationManager — urgency-based alerting to @owner.
///
/// URGENCY ROUTING:
///   critical → immediate notification (always)
///   high     → immediate notification
///   medium   → queued for daily digest (unless forceImmediate)
///   low      → queued for daily digest
///
/// Daily digest: written to AtKey "digest.$date.safeclaw@owner" (TTL 30 d).
///
/// All notifications go to @owner's atServer via sharedWith = @owner.
/// The Flutter app subscribes to "safeclaw\.notify\..*" to surface them.

import 'dart:convert';
import 'dart:io';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../models/task.dart';

class NotificationManager {
  final AtClient atClient;
  final Logger _log = Logger('NotificationManager');

  /// Resolved at construction from OWNER_AT_SIGN env var (set by docker-compose).
  final String _ownerAtSign;
  static const String _namespace = 'safeclaw';
  static const int _digestTtlMs = 30 * 24 * 60 * 60 * 1000; // 30 days

  // In-memory queue for medium/low urgency alerts.
  final List<Alert> _digestQueue = [];

  NotificationManager({required this.atClient})
      : _ownerAtSign = Platform.environment['OWNER_AT_SIGN'] ?? '@owner';

  // ──────────────────────────────────────────────────────────
  //  PUBLIC API
  // ──────────────────────────────────────────────────────────

  Future<void> sendAlert(Alert alert) async {
    switch (alert.urgency) {
      case NotificationUrgency.critical:
      case NotificationUrgency.high:
        await _sendImmediate(alert);
        break;
      case NotificationUrgency.medium:
      case NotificationUrgency.low:
        if (alert.forceImmediate) {
          await _sendImmediate(alert);
        } else {
          _digestQueue.add(alert);
          _log.fine('Alert queued for digest: ${alert.title}');
        }
        break;
    }
  }

  /// Flush the digest queue to @owner.
  /// Called by HeartbeatEngine once per day (or on shutdown).
  Future<void> flushDailyDigest() async {
    if (_digestQueue.isEmpty) return;

    final date =
        DateTime.now().toUtc().toIso8601String().substring(0, 10); // YYYY-MM-DD
    final digestKey = (AtKey.shared(
      'digest.$date',
      namespace: _namespace,
      sharedBy: atClient.getCurrentAtSign() ?? '@agent',
    )..sharedWith(_ownerAtSign))
        .build()
      ..metadata = (Metadata()
        ..ttl = _digestTtlMs
        ..ttr = -1);

    final payload = jsonEncode({
      'date': date,
      'count': _digestQueue.length,
      'alerts': _digestQueue.map((a) => a.toJson()).toList(),
    });

    try {
      await atClient.put(
        digestKey,
        payload,
        putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
      );

      // Also send a single notification so the Flutter app surfaces it.
      final notifKey = (AtKey.shared(
        'notify.digest.$date',
        namespace: _namespace,
        sharedBy: atClient.getCurrentAtSign() ?? '@agent',
      )..sharedWith(_ownerAtSign))
          .build()
        ..metadata = (Metadata()
          ..ttl = 86400000 // 24 h
          ..ttr = -1);

      await atClient.notificationService.notify(
        NotificationParams.forUpdate(
          notifKey,
          value: jsonEncode({
            'title': 'SafeClaw Daily Digest ($date)',
            'count': _digestQueue.length,
          }),
        ),
      );

      _log.info('Daily digest flushed: ${_digestQueue.length} alerts');
      _digestQueue.clear();
    } catch (e) {
      _log.warning('Failed to flush daily digest: $e');
    }
  }

  // ──────────────────────────────────────────────────────────
  //  IMPLEMENTATION
  // ──────────────────────────────────────────────────────────

  Future<void> _sendImmediate(Alert alert) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final notifKey = (AtKey.shared(
      'notify.${alert.urgency.name}.$ts',
      namespace: _namespace,
      sharedBy: atClient.getCurrentAtSign() ?? '@agent',
    )..sharedWith(_ownerAtSign))
        .build()
      ..metadata = (Metadata()
        ..ttl = _urgencyTtl(alert.urgency)
        ..ttr = -1);

    try {
      await atClient.notificationService.notify(
        NotificationParams.forUpdate(
          notifKey,
          value: jsonEncode(alert.toJson()),
        ),
      );
      _log.info(
          '[${alert.urgency.name.toUpperCase()}] ${alert.title}: ${alert.message}');
    } catch (e) {
      _log.warning('Failed to send immediate alert: $e');
    }
  }

  int _urgencyTtl(NotificationUrgency urgency) {
    switch (urgency) {
      case NotificationUrgency.critical:
        return 7 * 24 * 60 * 60 * 1000; // 7 days
      case NotificationUrgency.high:
        return 3 * 24 * 60 * 60 * 1000; // 3 days
      case NotificationUrgency.medium:
        return 24 * 60 * 60 * 1000; // 1 day
      case NotificationUrgency.low:
        return 12 * 60 * 60 * 1000; // 12 hours
    }
  }
}
