/// DataService — reads and writes AtKeys from @owner's atServer for the Flutter UI.
///
/// Provides:
///   - Audit log entries    (read from @owner — written there by the agent)
///   - Pending HITL requests
///   - Installed skills     (read/write — owner declares skills, shared w/ @agent)
///   - Conversation history (AtKey-backed, SharedPreferences used as offline cache)
///
/// SKILL KEY PATTERN (on @owner's atServer, sharedWith @agent):
///   skill_meta.<skillId>.pembrook@<owner>  →  JSON-encoded SkillData
///
/// CONVERSATION HISTORY (synced across all owner devices via AtKey + sync notifications):
///   conversation_history.pembrook@<owner>  →  JSON array of ConversationSummary objects
///   conversation_history_deleted.pembrook@<owner>  →  JSON array of deleted conversation IDs (tombstones)
///   SharedPreferences key 'conversations'  →  same JSON (offline / startup cache)
///   SYNC: pembrook.conversation_sync.<timestamp> notification triggers instant reload on all devices
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
    final DateTime ts = rawTs is int ? DateTime.fromMillisecondsSinceEpoch(rawTs) : DateTime.parse(rawTs as String);
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

  /// Whether this skill needs outbound network access.
  /// When true the sandbox runs with --network=bridge instead of --network=none.
  final bool requiresNetwork;

  const SkillData({
    required this.skillId,
    required this.skillAtSign,
    this.description = '',
    this.version = '1.0.0',
    this.trustScore = 0.0,
    this.enabled = true,
    this.config = const {},
    this.requiresNetwork = false,
  });

  SkillData copyWith({
    bool? enabled,
    Map<String, String>? config,
    bool? requiresNetwork,
  }) =>
      SkillData(
        skillId: skillId,
        skillAtSign: skillAtSign,
        description: description,
        version: version,
        trustScore: trustScore,
        enabled: enabled ?? this.enabled,
        config: config ?? this.config,
        requiresNetwork: requiresNetwork ?? this.requiresNetwork,
      );

  Map<String, dynamic> toJson() => {
        'skillId': skillId,
        'skillAtSign': skillAtSign,
        'description': description,
        'version': version,
        'trustScore': trustScore,
        'enabled': enabled,
        'config': config,
        'requiresNetwork': requiresNetwork,
      };

  factory SkillData.fromJson(Map<String, dynamic> json) => SkillData(
        skillId: json['skillId'] as String? ?? '',
        skillAtSign: json['skillAtSign'] as String? ?? '',
        description: json['description'] as String? ?? '',
        version: json['version'] as String? ?? '1.0.0',
        trustScore: (json['trustScore'] as num?)?.toDouble() ?? 0.0,
        enabled: json['enabled'] as bool? ?? true,
        config: (json['config'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, v.toString())),
        requiresNetwork: json['requiresNetwork'] as bool? ?? false,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
//  DataService
// ─────────────────────────────────────────────────────────────────────────────

class DataService extends ChangeNotifier {
  AtClient? _atClient;
  String _agentAtSign = '@agent';
  static const String _namespace = 'pembrook';

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
        ..auth = true
        ..showHiddenKeys = true;
      final result = await remote.executeVerb(scanBuilder);
      if (result.isEmpty) return [];
      final jsonStr = result.replaceFirst('data:', '').trim();
      if (jsonStr == 'null' || jsonStr.isEmpty) return [];
      final raw = (jsonDecode(jsonStr) as List<dynamic>).cast<String>();
      // Strip "cached:" prefix — put() from @agent caches keys on @owner's
      // secondary with this prefix, which AtKey.fromString() cannot parse.
      return raw.map((k) => k.startsWith('cached:') ? k.substring(7) : k).toList();
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
          final v = await _atClient!.get(atKey, getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
          if (v.value != null) {
            items.add(HitlItem.fromJson(jsonDecode(v.value as String) as Map<String, dynamic>));
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
      final allKeys = await _remoteKeys(r'audit\.');
      // Only keep current-namespace entries from agent; sort newest-first.
      final suffix = '.pembrook$_agentAtSign';
      final keys = allKeys.where((k) => k.endsWith(suffix)).toList()
        ..sort((a, b) {
          final partsA = a.split('.');
          final partsB = b.split('.');
          final tsA = partsA.length > 1 ? (int.tryParse(partsA[1]) ?? 0) : 0;
          final tsB = partsB.length > 1 ? (int.tryParse(partsB[1]) ?? 0) : 0;
          return tsB.compareTo(tsA);
        });
      final items = <AuditItem>[];
      for (final keyStr in keys.take(200)) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await _atClient!.get(atKey, getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
          if (v.value != null) {
            final item = AuditItem.fromJson(jsonDecode(v.value as String) as Map<String, dynamic>);
            final t = item.actionType;
            if (t.startsWith('mcp.') || t.startsWith('task.run.') || t.startsWith('skill.') || t.startsWith('tool.')) {
              items.add(item);
            }
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
      // Use _remoteKeys so skills are visible immediately after login,
      // before the local secondary cache has had time to sync.
      final keys = await _remoteKeys(r'skill_meta\.');
      final items = <SkillData>[];
      for (final keyStr in keys) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await _atClient!.get(atKey, getRequestOptions: GetRequestOptions()..useRemoteAtServer = true);
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

  /// Reload only skills from the remote server. Cheaper than a full refresh()
  /// and used by SkillsScreen on mount so the list is always fresh.
  Future<void> refreshSkills() async {
    if (_atClient == null) return;
    _loading = true;
    notifyListeners();
    await _loadSkills();
    _loading = false;
    notifyListeners();
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
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
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

  factory ConversationSummary.fromJson(Map<String, dynamic> json) => ConversationSummary(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '(untitled)',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        messages: (json['messages'] as List<dynamic>? ?? [])
            .map((e) => StoredMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Persists conversation history — synced across all owner devices via AtKey.
///
/// On load: tries the remote AtKey first; falls back to SharedPreferences for
/// offline / unauthenticated startup.  On save/delete: writes to both stores
/// AND sends a sync notification to trigger instant reload on all devices.
///
/// AtKeys:
///   - `conversation_history.pembrook@<owner>` — list of conversations
///   - `conversation_history_deleted.pembrook@<owner>` — tombstones (deleted IDs)
/// SharedPreferences key: `'conversations'` (local offline cache).
/// Sync notifications: `pembrook.conversation_sync.<timestamp>` sent to self,
/// all devices subscribe and reload instantly when they receive it.
///
/// Tombstones ensure deletions propagate correctly: when Device A deletes a
/// conversation, the ID is added to the tombstone set which is synced via AtKey.
/// Device B filters out tombstoned IDs when loading, preventing resurrections.
///
/// Stores up to [maxConversations] sessions.  Oldest sessions are pruned
/// when the limit is exceeded.
class ConversationStore extends ChangeNotifier {
  static const String _prefsKey = 'conversations';
  static const String _deletedPrefsKey = 'conversations_deleted';
  static const String _atKeyName = 'conversation_history';
  static const String _deletedAtKeyName = 'conversation_history_deleted';
  static const String _namespace = 'pembrook';
  static const int maxConversations = 100;
  static const int maxTombstones = 500;

  AtClient? _atClient;
  List<ConversationSummary> _conversations = [];
  // Tombstone set: IDs of deleted conversations that should be filtered out
  // when merging remote data. Synced across devices to ensure deletions propagate.
  Set<String> _deletedIds = {};
  // Monotonically-increasing counter used to discard stale load() results.
  // Each load() call captures the epoch at entry; if a newer call has already
  // applied its data by the time this one finishes, we skip the overwrite.
  int _loadEpoch = 0;
  // Subscription to custom sync notification for instant cross-device updates.
  // We send notifications to ourselves when conversations change.
  StreamSubscription<AtNotification>? _syncSubscription;

  List<ConversationSummary> get conversations => List.unmodifiable(_conversations);

  /// Call after authentication to enable cross-device AtKey sync.
  ///
  /// Immediately populates the list from the local SharedPreferences cache so
  /// the UI shows history instantly, then refreshes from the remote atServer
  /// in the background so multi-device changes arrive without blocking login.
  Future<void> initialise(AtClient atClient) async {
    _atClient = atClient;
    // 1. Fast local cache — available offline, shows UI immediately.
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_prefsKey);
    final cachedDeleted = prefs.getString(_deletedPrefsKey);
    if (cachedDeleted != null && cachedDeleted.isNotEmpty) {
      _loadDeletedFromJson(cachedDeleted);
    }
    if (cached != null && cached.isNotEmpty) {
      _loadFromJson(cached); // calls notifyListeners()
    }
    // 2. Remote refresh in the background — updates list when it arrives.
    load().ignore();
    // 3. Subscribe to conversation sync notifications for instant cross-device updates.
    debugPrint('[ConversationStore] Initializing with atClient: ${atClient.getCurrentAtSign()}');
    _subscribeToSyncNotifications();
  }

  /// Load conversations — tries remote AtKey first, then SharedPreferences.
  ///
  /// Uses an epoch counter so concurrent calls never cause stale data to
  /// overwrite the most-recently-applied result.  This prevents the background
  /// load started during login (which fetches a snapshot from before the
  /// originating device's AtKey write) from clobbering the fresh data loaded
  /// by the cross-device sync listener 3 s later.
  ///
  /// Also loads the tombstone set (deleted IDs) and filters them out so
  /// deletions performed on Device A propagate to Device B.
  Future<void> load() async {
    final epoch = ++_loadEpoch;
    final client = _atClient;
    if (client != null) {
      try {
        // Load tombstones first so we can filter deletions when loading conversations.
        final deletedKey = AtKey()
          ..key = _deletedAtKeyName
          ..namespace = _namespace;
        try {
          final deletedValue = await client.get(
            deletedKey,
            getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
          );
          if (deletedValue.value != null && epoch >= _loadEpoch) {
            _loadDeletedFromJson(deletedValue.value as String);
          }
        } catch (_) {
          // Tombstone key doesn't exist yet or network error — not fatal.
        }

        // A newer load() call has already applied its result — discard ours.
        if (epoch < _loadEpoch) return;

        final key = AtKey()
          ..key = _atKeyName
          ..namespace = _namespace;
        final atValue = await client.get(
          key,
          getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
        );
        // A newer load() call has already applied its result — discard ours.
        if (epoch < _loadEpoch) return;
        if (atValue.value != null) {
          final raw = atValue.value as String;
          _loadFromJson(raw);
          // Keep local cache in sync so the next offline startup has fresh data.
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefsKey, raw);
          await prefs.setString(_deletedPrefsKey, jsonEncode(_deletedIds.toList()));
          return;
        }
      } catch (_) {
        // Network/AtKey unavailable — fall through to SharedPreferences.
      }
    }

    // A newer load() call has already applied its result — discard ours.
    if (epoch < _loadEpoch) return;

    // Offline / unauthenticated fallback.
    final prefs = await SharedPreferences.getInstance();
    final deletedRaw = prefs.getString(_deletedPrefsKey);
    if (deletedRaw != null && deletedRaw.isNotEmpty) {
      _loadDeletedFromJson(deletedRaw);
    }
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _conversations = [];
      notifyListeners();
      return;
    }
    _loadFromJson(raw);
  }

  void _loadFromJson(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _conversations = list
          .map((e) => ConversationSummary.fromJson(e as Map<String, dynamic>))
          .where((conv) => !_deletedIds.contains(conv.id)) // Filter tombstones
          .toList();
      _conversations.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      _conversations = [];
    }
    notifyListeners();
  }

  void _loadDeletedFromJson(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _deletedIds = Set<String>.from(list);
      // Prune old tombstones to prevent unbounded growth.
      if (_deletedIds.length > maxTombstones) {
        _deletedIds = _deletedIds.skip(_deletedIds.length - maxTombstones).toSet();
      }
    } catch (_) {
      _deletedIds = {};
    }
  }

  /// Save (or overwrite) a conversation session.
  ///
  /// If [messages] contains no user messages the save is skipped so empty
  /// "new conversation" sessions are not cluttered into the list.
  /// Append a push notification message to an existing conversation (or create
  /// a placeholder entry so the badge in History points to a visible tile).
  ///
  /// Unlike [save], this is allowed on conversations that have no user messages
  /// (e.g. a task result that arrived after the scheduling conversation was
  /// navigated away from but not yet persisted).
  Future<void> appendPushMessage(String convId, String title, StoredMessage msg) async {
    final idx = _conversations.indexWhere((c) => c.id == convId);
    if (idx >= 0) {
      // Append to existing conversation.
      final existing = _conversations[idx];
      _conversations[idx] = ConversationSummary(
        id: existing.id,
        title: existing.title,
        createdAt: existing.createdAt,
        messages: [...existing.messages, msg],
      );
    } else {
      // Create a placeholder so the History list has a visible tile to badge.
      _conversations.insert(
        0,
        ConversationSummary(
          id: convId,
          title: title,
          createdAt: msg.timestamp,
          messages: [msg],
        ),
      );
    }
    if (_conversations.length > maxConversations) {
      _conversations = _conversations.sublist(0, maxConversations);
    }
    await _persist();
    notifyListeners();
  }

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
  ///
  /// Adds the ID to the tombstone set so the deletion syncs across devices.
  Future<void> delete(String id) async {
    debugPrint('[ConversationStore] Deleting conversation: $id');
    _deletedIds.add(id);
    _conversations.removeWhere((c) => c.id == id);
    await _persist();
    notifyListeners();
    debugPrint('[ConversationStore] Delete complete, UI notified');
  }

  /// Delete multiple conversations by ID in a single batch.
  ///
  /// Adds all IDs to the tombstone set so deletions sync across devices.
  Future<void> deleteMany(Set<String> ids) async {
    if (ids.isEmpty) return;
    debugPrint('[ConversationStore] Deleting ${ids.length} conversations');
    _deletedIds.addAll(ids);
    _conversations.removeWhere((c) => ids.contains(c.id));
    await _persist();
    notifyListeners();
    debugPrint('[ConversationStore] Batch delete complete, UI notified');
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
    final json = jsonEncode(_conversations.map((c) => c.toJson()).toList());
    final deletedJson = jsonEncode(_deletedIds.toList());

    // 1. Local cache — immediate, offline-safe.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, json);
    await prefs.setString(_deletedPrefsKey, deletedJson);

    // 2. Remote AtKey — synced to all owner devices via atPlatform.
    final client = _atClient;
    if (client != null) {
      try {
        // Persist tombstones first so Device B always has the deletion list
        // before it processes any conversation updates.
        final deletedKey = AtKey()
          ..key = _deletedAtKeyName
          ..namespace = _namespace
          ..metadata = (Metadata()..ttr = -1);
        await client.put(
          deletedKey,
          deletedJson,
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        );

        final key = AtKey()
          ..key = _atKeyName
          ..namespace = _namespace
          ..metadata = (Metadata()..ttr = -1);
        await client.put(
          key,
          json,
          putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
        );

        // Send a sync notification to all devices (including this one).
        // Self-key put() doesn't auto-notify, so we send a custom sync signal.
        try {
          final syncKey = AtKey()
            ..key = 'pembrook.conversation_sync.${DateTime.now().millisecondsSinceEpoch}'
            ..namespace = 'pembrook'
            ..sharedWith = client.getCurrentAtSign()
            ..metadata = (Metadata()..ttl = 10000); // 10 second TTL

          debugPrint('[ConversationStore] Sending sync notification to trigger cross-device reload');
          await client.notificationService.notify(
            NotificationParams.forUpdate(syncKey, value: 'sync'),
          );
          debugPrint('[ConversationStore] Sync notification sent successfully');
        } catch (e) {
          debugPrint('[ConversationStore] Sync notification failed: $e');
          // Notification failure is non-fatal.
        }
      } catch (_) {
        // AtKey write failure is non-fatal; local cache still saved.
      }
    }
  }

  /// Subscribe to conversation sync notifications for instant cross-device updates.
  ///
  /// When any device modifies conversations, it sends a sync notification to
  /// all devices (including itself). This triggers an immediate reload.
  void _subscribeToSyncNotifications() {
    _syncSubscription?.cancel();
    final client = _atClient;
    if (client == null) {
      debugPrint('[ConversationStore] Cannot subscribe: atClient is null');
      return;
    }

    debugPrint('[ConversationStore] Subscribing to conversation sync notifications...');

    _syncSubscription = client.notificationService
        .subscribe(
      regex: r'pembrook\.conversation_sync\..*',
      shouldDecrypt: true,
    )
        .listen((notification) {
      debugPrint('[ConversationStore] Received sync notification from ${notification.from}');
      load().then((_) {
        debugPrint('[ConversationStore] Reload complete after sync notification');
      });
    }, onError: (error) {
      debugPrint('[ConversationStore] Sync subscription error: $error');
    });

    debugPrint('[ConversationStore] Sync subscription active');
  }

  @override
  void dispose() {
    _syncSubscription?.cancel();
    super.dispose();
  }
}
