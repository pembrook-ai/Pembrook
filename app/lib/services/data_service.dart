/// DataService — reads and writes AtKeys from @owner's atServer for the Flutter UI.
///
/// Provides:
///   - Audit log entries    (read from @owner — written there by the agent)
///   - Pending HITL requests
///   - Installed skills     (read/write — owner declares skills, shared w/ @agent)
///
/// SKILL KEY PATTERN (on @owner's atServer, sharedWith @agent):
///   skill_meta.<skillId>.safeclaw@<owner>  →  JSON-encoded SkillData
///
/// Agent atSign: loaded from SharedPreferences 'agentAtSign' (same source as
/// RpcService so they stay in sync when the user updates Settings).

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Models
// ─────────────────────────────────────────────────────────────────────────────

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

/// A skill registered by the owner and shared with the agent.
class SkillData {
  final String skillId;

  /// The skill's own atSign (or @agent with a skill sub-namespace).
  final String skillAtSign;

  final String description;
  final String version;
  final double trustScore;
  final bool enabled;

  /// Optional key-value pairs passed to the skill at invocation time.
  /// Examples: {'smtp_host': 'smtp.example.com', 'from_address': '...'}
  final Map<String, String> config;

  const SkillData({
    required this.skillId,
    required this.skillAtSign,
    this.description = '',
    this.version = '1.0.0',
    this.trustScore = 0.0,
    this.enabled = true,
    this.config = const {},
  });

  SkillData copyWith({bool? enabled}) => SkillData(
        skillId: skillId,
        skillAtSign: skillAtSign,
        description: description,
        version: version,
        trustScore: trustScore,
        enabled: enabled ?? this.enabled,
        config: config,
      );

  Map<String, dynamic> toJson() => {
        'skillId': skillId,
        'skillAtSign': skillAtSign,
        'description': description,
        'version': version,
        'trustScore': trustScore,
        'enabled': enabled,
        'config': config,
      };

  factory SkillData.fromJson(Map<String, dynamic> json) => SkillData(
        skillId: json['skillId'] as String? ?? '',
        skillAtSign: json['skillAtSign'] as String? ?? '',
        description: json['description'] as String? ?? '',
        version: json['version'] as String? ?? '1.0.0',
        trustScore: (json['trustScore'] as num?)?.toDouble() ?? 0.0,
        enabled: json['enabled'] as bool? ?? true,
        config: (json['config'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v.toString())),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
//  DataService
// ─────────────────────────────────────────────────────────────────────────────

class DataService extends ChangeNotifier {
  AtClient? _atClient;
  String _agentAtSign = '@agent';
  static const String _namespace = 'safeclaw';

  List<HitlItem> _pendingHitl = [];
  List<AuditItem> _auditEntries = [];
  List<SkillData> _skills = [];
  bool _loading = false;

  List<HitlItem> get pendingHitl => _pendingHitl;
  List<AuditItem> get auditEntries => _auditEntries;
  List<SkillData> get skills => _skills;
  bool get loading => _loading;

  Future<void> initialise(AtClient atClient) async {
    _atClient = atClient;
    final prefs = await SharedPreferences.getInstance();
    _agentAtSign = prefs.getString('agentAtSign') ?? '@agent';
    await refresh();
  }

  Future<void> refresh() async {
    if (_atClient == null) return;
    _loading = true;
    notifyListeners();

    await Future.wait([
      _loadAuditEntries(),
      _loadPendingHitl(),
      _loadSkills(),
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

  // ──────────────────────────────────────────────────────────
  //  SKILLS
  // ──────────────────────────────────────────────────────────

  AtKey _skillKey(String skillId) => (AtKey.shared(
        'skill_meta.$skillId',
        namespace: _namespace,
        sharedBy: _atClient!.getCurrentAtSign() ?? '',
      )..sharedWith(_agentAtSign))
          .build()
        ..metadata = (Metadata()..ttr = -1);

  Future<void> _loadSkills() async {
    if (_atClient == null) return;
    try {
      final keys = await _atClient!.getKeys(regex: r'skill_meta\.');
      final items = <SkillData>[];
      for (final keyStr in keys) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await _atClient!.get(atKey,
              getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
          if (v.value != null) {
            final data = jsonDecode(v.value as String) as Map<String, dynamic>;
            items.add(SkillData.fromJson(data));
          }
        } catch (_) {}
      }
      items.sort((a, b) => a.skillId.compareTo(b.skillId));
      _skills = items;
    } catch (_) {
      _skills = [];
    }
  }

  /// Register or update a skill. Stored on @owner's atServer, sharedWith @agent.
  Future<void> saveSkill(SkillData skill) async {
    if (_atClient == null) return;
    await _atClient!.put(
      _skillKey(skill.skillId),
      jsonEncode(skill.toJson()),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
    // Update local list immediately.
    final idx = _skills.indexWhere((s) => s.skillId == skill.skillId);
    if (idx >= 0) {
      _skills[idx] = skill;
    } else {
      _skills
        ..add(skill)
        ..sort((a, b) => a.skillId.compareTo(b.skillId));
    }
    notifyListeners();
  }

  /// Remove a skill registration.
  Future<void> removeSkill(String skillId) async {
    if (_atClient == null) return;
    await _atClient!.delete(_skillKey(skillId));
    _skills.removeWhere((s) => s.skillId == skillId);
    notifyListeners();
  }
}
