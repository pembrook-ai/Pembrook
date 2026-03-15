/// AuditService — immutable audit trail stored on @owner's atServer.
///
/// SECURITY DESIGN:
///   - Audit entries are stored on @owner's atServer (NOT @agent's).
///     The agent writes them with sharedWith=@owner, so they are on the
///     owner's server — the agent cannot delete its own audit log.
///   - Each entry uses Metadata()..immutable = true — once written, it
///     CANNOT be modified even by @owner.
///   - Keys use useRemoteAtServer=true so they bypass the local cache
///     and go directly to the cloud secondary.
///
/// Key pattern: audit.$timestamp.$actionId.pembrook@owner
///   Created by @agent, sharedWith @owner; stored on @owner's atServer.
///
/// Policy violations additionally trigger an immediate notification to @owner.
///
/// Phase 1: basic logging.
/// Phase 2: add content hashing, alerting thresholds, periodic reports.

import 'dart:convert';
import 'dart:io';
import 'package:at_client/at_client.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../models/audit_entry.dart';

class AuditService {
  final AtClient atClient;
  final Logger _log = Logger('AuditService');
  final Uuid _uuid = const Uuid();

  /// Resolved at construction from OWNER_AT_SIGN env var (set by docker-compose).
  final String _ownerAtSign;

  AuditService({required this.atClient})
      : _ownerAtSign = Platform.environment['OWNER_AT_SIGN'] ?? '@owner';

  /// Compute a SHA-256 hex digest of [text].
  ///
  /// Used by callers to generate tamper-evident hashes for audit entries.
  static String contentHash(String text) =>
      sha256.convert(utf8.encode(text)).toString();

  /// Write an immutable audit entry to @owner's atServer.
  ///
  /// This write goes directly to the cloud — no local-only caching.
  Future<void> log(AuditEntry entry) async {
    final ts = entry.timestamp.millisecondsSinceEpoch;
    final actionId = _uuid.v4().replaceAll('-', '');

    // Key stored on @owner's atServer via sharedWith
    final auditKey = (AtKey.shared(
      'audit.$ts.$actionId',
      namespace: 'pembrook',
      sharedBy: atClient.getCurrentAtSign() ?? '@agent',
    )..sharedWith(_ownerAtSign))
        .build()
      ..metadata = (Metadata()
            ..immutable = true // value CANNOT be changed after creation
            ..ttl =
                7 * 24 * 60 * 60 * 1000 // 7-day TTL — auto-expires old entries
            ..ttr = -1 // no time-to-refresh
          );

    try {
      await atClient.put(
        auditKey,
        jsonEncode(entry.toJson()),
        putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
      );

      _log.fine('Audit logged: ${entry.actionType} by ${entry.initiatorAtSign} '
          '→ ${entry.policyDecision}');
    } catch (e) {
      // Audit failures are logged to stderr but never suppress the main operation.
      // A future enhancement: buffer failed writes and retry.
      _log.warning('Failed to write audit entry: $e');
    }

    // ── Policy violation alerting ─────────────────────────────────────────
    if (entry.policyDecision == 'denied' ||
        entry.policyDecision == 'escalated') {
      await _alertOnViolation(entry);
    }
  }

  /// Send an immediate notification to @owner on policy violations.
  Future<void> _alertOnViolation(AuditEntry entry) async {
    try {
      final alertKey = AtKey()
        ..key = 'alert.policy.${DateTime.now().millisecondsSinceEpoch}'
        ..namespace = 'pembrook'
        ..sharedWith = _ownerAtSign
        ..metadata = (Metadata()
          ..ttl = 3600000 // 1 hour TTL
          ..ttr = -1);

      await atClient.notificationService.notify(
        NotificationParams.forUpdate(
          alertKey,
          value: jsonEncode({
            'title': 'Pembrook: Policy ${entry.policyDecision}',
            'message':
                'Action "${entry.actionType}" by ${entry.initiatorAtSign} '
                    'was ${entry.policyDecision}.\n${entry.notes ?? ""}',
            'urgency': 'medium',
            'timestamp': entry.timestamp.millisecondsSinceEpoch,
          }),
        ),
      );
    } catch (e) {
      _log.warning('Failed to send policy violation alert: $e');
    }
  }

  /// Query recent audit entries (for the Flutter app audit viewer).
  ///
  /// Lists audit keys from @owner's atServer and returns them sorted
  /// by timestamp descending.
  Future<List<AuditEntry>> getRecentEntries({int limit = 50}) async {
    try {
      final keys = await atClient.getKeys(
        regex: r'^audit\.',
      );

      final entries = <AuditEntry>[];
      for (final keyStr in keys.take(limit)) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final atValue = await atClient.get(atKey);
          if (atValue.value != null) {
            entries.add(AuditEntry.fromJson(
                jsonDecode(atValue.value as String) as Map<String, dynamic>));
          }
        } catch (_) {}
      }

      entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return entries;
    } catch (e) {
      _log.warning('Failed to retrieve audit entries: $e');
      return [];
    }
  }
}
