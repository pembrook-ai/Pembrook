/// DataService — reads and writes AtKeys from @owner's atServer for the Flutter UI.
///
/// Provides:
///   - Audit log entries    (read from @owner — written there by the agent)
///   - Pending HITL requests
///   - Installed skills     (read/write — owner declares skills, shared w/ @agent)
///   - Conversation history (stored locally in SharedPreferences)
///
/// SKILL KEY PATTERN (on @owner's atServer, sharedWith @agent):
///   skill_meta.<skillId>.safeclaw@<owner>  →  JSON-encoded SkillData
///
/// CONVERSATION HISTORY (local SharedPreferences):
///   Key: 'conversations'  →  JSON array of ConversationSummary objects
///
/// Agent atSign: loaded from SharedPreferences 'agentAtSign' (same source as
/// RpcService so they stay in sync when the user updates Settings).

import 'dart:async';
import 'dart:convert';

import 'package:at_client/at_client.dart';
import 'package:at_commons/at_builders.dart';
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
  final String? targetResource;
  final int? executionDurationMs;
  final String? skillId;
  final String? mcpServer;
  final String? inputHash;
  final String? outputHash;
  final String? notes;

  const AuditItem({
    required this.timestamp,
    required this.actionType,
    required this.initiatorAtSign,
    required this.policyDecision,
    this.targetResource,
    this.executionDurationMs,
    this.skillId,
    this.mcpServer,
    this.inputHash,
    this.outputHash,
    this.notes,
  });

  factory AuditItem.fromJson(Map<String, dynamic> json) {
    // The agent writes timestamp as millisecondsSinceEpoch (int).
    // Guard against older entries that may have stored an ISO string.
    final rawTs = json['timestamp'];
    final DateTime ts = rawTs is int
        ? DateTime.fromMillisecondsSinceEpoch(rawTs)
        : DateTime.parse(rawTs as String);
    return AuditItem(
      timestamp: ts,
      actionType: json['actionType'] as String,
      initiatorAtSign: json['initiatorAtSign'] as String,
      policyDecision: json['policyDecision'] as String,
      targetResource: json['targetResource'] as String?,
      executionDurationMs: json['executionDurationMs'] as int?,
      skillId: json['skillId'] as String?,
      mcpServer: json['mcpServer'] as String?,
      inputHash: json['inputHash'] as String?,
      outputHash: json['outputHash'] as String?,
      notes: json['notes'] as String?,
    );
  }
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

  /// Scan the **remote** secondary for keys matching [regex].
  ///
  /// Bypasses the local secondary store entirely — keys written by the agent
  /// with useRemoteAtServer=true are immediately visible without waiting for sync.
  Future<List<String>> _remoteKeys(String regex) async {
    try {
      final remote = _atClient!.getRemoteSecondary();
      if (remote == null) return [];
      final scanBuilder = ScanVerbBuilder()
        ..regex = regex
        ..auth = true;
      final result = await remote.executeVerb(scanBuilder);
      if (result.isEmpty) return [];
      // Response format: data:["key1","key2",...]
      final jsonStr = result.replaceFirst('data:', '').trim();
      if (jsonStr == 'null' || jsonStr.isEmpty) return [];
      return (jsonDecode(jsonStr) as List<dynamic>).cast<String>();
    } catch (_) {
      // Fall back to local key scan if remote scan fails.
      return _atClient!.getKeys(regex: regex);
    }
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
      final keys = await _remoteKeys(r'hitl\.pending\.');
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

  /// Delete audit entries whose key-embedded timestamp is older than [maxAgeDays].
  /// New entries have a 7-day TTL and expire automatically; this handles legacy
  /// entries that were written before TTL was introduced.
  Future<void> cleanupOldAuditLogs({int maxAgeDays = 7}) async {
    if (_atClient == null) return;
    final cutoffMs =
        DateTime.now().millisecondsSinceEpoch - maxAgeDays * 86400000;
    try {
      final keys = await _remoteKeys(r'audit\.');
      for (final keyStr in keys) {
        try {
          // Key pattern: (@owner:)audit.<timestampMs>.<id>.safeclaw@agent
          final bare = keyStr.contains(':') ? keyStr.split(':').last : keyStr;
          final segments = bare.split('.');
          // segments[0]='audit', segments[1]=timestampMs
          if (segments.length >= 2) {
            final ts = int.tryParse(segments[1]);
            if (ts != null && ts < cutoffMs) {
              final atKey = AtKey.fromString(keyStr);
              await _atClient!.delete(atKey);
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _loadAuditEntries() async {
    if (_atClient == null) return;
    // Clean up old entries (no TTL) in the background — don't await.
    unawaited(cleanupOldAuditLogs());
    try {
      final keys = await _remoteKeys(r'audit\.');
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

// ─────────────────────────────────────────────────────────────────────────────
//  Conversation History (local storage)
// ─────────────────────────────────────────────────────────────────────────────

/// A single message in a stored conversation.
class StoredMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  const StoredMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'isUser': isUser,
        'timestamp': timestamp.toIso8601String(),
      };

  factory StoredMessage.fromJson(Map<String, dynamic> json) => StoredMessage(
        text: json['text'] as String? ?? '',
        isUser: json['isUser'] as bool? ?? false,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// Summary + full message list for one conversation session.
class ConversationSummary {
  final String id;

  /// The first user message (truncated to 80 chars) used as the display title.
  final String title;

  final DateTime createdAt;
  final List<StoredMessage> messages;

  const ConversationSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
  });

  int get messageCount => messages.length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ConversationSummary.fromJson(Map<String, dynamic> json) =>
      ConversationSummary(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '(untitled)',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        messages: (json['messages'] as List<dynamic>? ?? [])
            .map((e) => StoredMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Persists conversation history in SharedPreferences.
///
/// Stores up to [maxConversations] sessions.  Oldest sessions are pruned
/// when the limit is exceeded.
class ConversationStore extends ChangeNotifier {
  static const String _prefsKey = 'conversations';
  static const int maxConversations = 100;

  List<ConversationSummary> _conversations = [];

  List<ConversationSummary> get conversations =>
      List.unmodifiable(_conversations);

  /// Load all conversations from SharedPreferences.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _conversations = [];
      notifyListeners();
      return;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _conversations = list
          .map((e) => ConversationSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      // Sort newest-first.
      _conversations.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      _conversations = [];
    }
    notifyListeners();
  }

  /// Save (or overwrite) a conversation session.
  ///
  /// If [messages] contains no user messages the save is skipped so empty
  /// "new conversation" sessions are not cluttered into the list.
  Future<void> save(ConversationSummary summary) async {
    if (summary.messages.every((m) => !m.isUser)) return;

    final idx = _conversations.indexWhere((c) => c.id == summary.id);
    if (idx >= 0) {
      _conversations[idx] = summary;
    } else {
      _conversations.insert(0, summary);
    }

    // Prune oldest if over limit.
    if (_conversations.length > maxConversations) {
      _conversations = _conversations.sublist(0, maxConversations);
    }

    await _persist();
    notifyListeners();
  }

  /// Delete a conversation by ID.
  Future<void> delete(String id) async {
    _conversations.removeWhere((c) => c.id == id);
    await _persist();
    notifyListeners();
  }

  /// Returns the conversation with [id], or null.
  ConversationSummary? get(String id) {
    try {
      return _conversations.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_conversations.map((c) => c.toJson()).toList()),
    );
  }
}
