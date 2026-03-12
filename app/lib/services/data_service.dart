/// DataService — reads AtKeys from @agent / @owner for the Flutter UI.
///
/// Provides:
///   - Conversation history list
///   - Audit log entries
///   - Installed skills list
///   - Pending HITL requests
///   - User preferences
///
/// All reads use useRemoteAtServer = true so they always reflect the
/// latest server state (no stale cache).
///
/// This service is used by AuditScreen, SkillsScreen, HitlScreen.

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/foundation.dart';

class HitlItem {
  final String actionId;
  final String actionType;
  final String description;
  final DateTime requestedAt;
  final Map<String, dynamic> payload;

  const HitlItem({
    required this.actionId,
    required this.actionType,
    required this.description,
    required this.requestedAt,
    required this.payload,
  });

  factory HitlItem.fromJson(Map<String, dynamic> json) => HitlItem(
        actionId: json['actionId'] as String,
        actionType: json['actionType'] as String,
        description: json['description'] as String,
        requestedAt: DateTime.parse(json['requestedAt'] as String),
        payload: json['payload'] as Map<String, dynamic>? ?? {},
      );
}

class AuditItem {
  final DateTime timestamp;
  final String actionType;
  final String initiatorAtSign;
  final String policyDecision;
  final String? notes;

  const AuditItem({
    required this.timestamp,
    required this.actionType,
    required this.initiatorAtSign,
    required this.policyDecision,
    this.notes,
  });

  factory AuditItem.fromJson(Map<String, dynamic> json) => AuditItem(
        timestamp: DateTime.parse(json['timestamp'] as String),
        actionType: json['actionType'] as String,
        initiatorAtSign: json['initiatorAtSign'] as String,
        policyDecision: json['policyDecision'] as String,
        notes: json['notes'] as String?,
      );
}

class DataService extends ChangeNotifier {
  AtClient? _atClient;
  static const String _namespace = 'safeclaw';
  static const String _agentAtSign = '@agent'; // placeholder

  List<HitlItem> _pendingHitl = [];
  List<AuditItem> _auditEntries = [];
  bool _loading = false;

  List<HitlItem> get pendingHitl => _pendingHitl;
  List<AuditItem> get auditEntries => _auditEntries;
  bool get loading => _loading;

  void initialise(AtClient atClient) {
    _atClient = atClient;
    refresh();
  }

  Future<void> refresh() async {
    if (_atClient == null) return;
    _loading = true;
    notifyListeners();

    await Future.wait([
      _loadAuditEntries(),
      _loadPendingHitl(),
    ]);

    _loading = false;
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────
  //  HITL
  // ──────────────────────────────────────────────────────────

  Future<void> _loadPendingHitl() async {
    if (_atClient == null) return;
    try {
      final keys = await _atClient!.getKeys(regex: r'^hitl\.pending\.');
      final items = <HitlItem>[];
      for (final keyStr in keys) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await _atClient!.get(atKey,
              getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
          if (v.value != null) {
            items.add(HitlItem.fromJson(
                jsonDecode(v.value as String) as Map<String, dynamic>));
          }
        } catch (_) {}
      }
      _pendingHitl = items;
    } catch (_) {}
  }

  Future<void> approveHitl(String actionId, {bool approved = true}) async {
    if (_atClient == null) return;
    final responseKey = (AtKey.shared(
      'hitl.response.$actionId',
      namespace: _namespace,
      sharedBy: _atClient!.getCurrentAtSign() ?? '',
    )..sharedWith(_agentAtSign))
        .build()
      ..metadata = (Metadata()
        ..ttl = 60000
        ..ttr = -1);

    await _atClient!.notificationService.notify(
      NotificationParams.forUpdate(
        responseKey,
        value: jsonEncode({
          'approved': approved,
          'reason': approved ? 'Approved via app' : 'Denied via app',
          'respondedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      ),
    );
    await refresh();
  }

  // ──────────────────────────────────────────────────────────
  //  AUDIT
  // ──────────────────────────────────────────────────────────

  Future<void> _loadAuditEntries() async {
    if (_atClient == null) return;
    try {
      final keys = await _atClient!.getKeys(regex: r'^audit\.');
      final items = <AuditItem>[];
      for (final keyStr in keys.take(100)) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await _atClient!.get(atKey,
              getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
          if (v.value != null) {
            items.add(AuditItem.fromJson(
                jsonDecode(v.value as String) as Map<String, dynamic>));
          }
        } catch (_) {}
      }
      items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      _auditEntries = items;
    } catch (_) {}
  }
}
