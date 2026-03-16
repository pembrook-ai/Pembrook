/// SkillRegistry — CRUD for installed skills, stored as AtKeys.
///
/// KEY PATTERN:
///   skill_meta.$skillId.pembrook@agent
///     value: JSON-encoded SkillMetadata
///     Metadata: ttl=0 (permanent until deleted), sharedWith=self
///
/// Skills are installed by @owner via an AtRpc call to the gateway.
/// The registry validates the SkillMetadata (checks signatureHash format,
/// trust score range, etc.) before persisting.
///
/// Phase 3 will add cryptographic signature verification against
/// developerAtSign's public key.

import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';

import '../models/skill_metadata.dart';

class SkillRegistry {
  final AtClient atClient;
  final Logger _log = Logger('SkillRegistry');
  static const String _namespace = 'pembrook';

  /// In-memory cache — updated immediately on install/remove so that
  /// _buildTools() in the Orchestrator always sees the current state
  /// without waiting for a remote atServer round-trip.
  final Map<String, SkillMetadata> _cache = {};

  /// Read-only view of the in-memory cache for use by the Orchestrator.
  Map<String, SkillMetadata> get cachedSkills => Map.unmodifiable(_cache);

  SkillRegistry({required this.atClient});

  // ──────────────────────────────────────────────────────────
  //  INSTALL
  // ──────────────────────────────────────────────────────────

  /// Install (or update) a skill in the registry.
  ///
  /// Throws [ArgumentError] on invalid metadata.
  /// Returns the persisted [SkillMetadata].
  Future<SkillMetadata> installSkill(SkillMetadata meta) async {
    _validate(meta);

    final key = _metaKey(meta.skillId);

    await atClient.put(
      key,
      jsonEncode(meta.toJson()),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );

    _cache[meta.skillId] = meta; // update in-memory cache immediately

    // Keep the persisted skill index up to date
    final ids = await _readIndex();
    if (!ids.contains(meta.skillId)) {
      ids.add(meta.skillId);
      await _writeIndex(ids);
    }

    _log.info(
        'Skill installed: ${meta.skillId} (trust=${meta.trustScore.toStringAsFixed(2)})');
    return meta;
  }

  // ──────────────────────────────────────────────────────────
  //  REMOVE
  // ──────────────────────────────────────────────────────────

  Future<void> removeSkill(String skillId) async {
    await atClient.delete(_metaKey(skillId));
    _cache.remove(skillId); // update in-memory cache immediately

    // Keep the persisted skill index up to date
    final ids = await _readIndex();
    if (ids.remove(skillId)) await _writeIndex(ids);

    _log.info('Skill removed: $skillId');
  }

  // ──────────────────────────────────────────────────────────
  //  LOOKUP
  // ──────────────────────────────────────────────────────────

  /// Returns null if the skill is not installed.
  Future<SkillMetadata?> getSkill(String skillId) async {
    try {
      final result = await atClient.get(
        _metaKey(skillId),
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (result.value == null) return null;
      return SkillMetadata.fromJson(
          jsonDecode(result.value as String) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // ──────────────────────────────────────────────────────────
  //  INDEX KEY (persisted list of skill IDs)
  // ──────────────────────────────────────────────────────────

  /// A single key that holds a JSON-encoded List<String> of installed skillIds.
  /// Used at startup to enumerate skills without relying on getKeys() local cache.
  AtKey get _indexKey => AtKey()
    ..key = 'skill_index'
    ..namespace = _namespace
    ..metadata = (Metadata()
      ..ttl = 0
      ..ttr = -1);

  Future<List<String>> _readIndex() async {
    try {
      final v = await atClient.get(
        _indexKey,
        getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
      );
      if (v.value == null) return [];
      return List<String>.from(jsonDecode(v.value as String) as List);
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<String> ids) async {
    await atClient.put(
      _indexKey,
      jsonEncode(ids),
      putRequestOptions: PutRequestOptions()..useRemoteAtServer = true,
    );
  }

  // ──────────────────────────────────────────────────────────
  //  LIST
  // ──────────────────────────────────────────────────────────

  Future<List<SkillMetadata>> listInstalledSkills() async {
    try {
      final ids = await _readIndex();
      final result = <SkillMetadata>[];
      for (final id in ids) {
        final meta = await getSkill(id);
        if (meta != null) result.add(meta);
      }
      return result;
    } catch (e) {
      _log.warning('listInstalledSkills error: $e');
      return [];
    }
  }

  /// Populate the in-memory cache from the remote atServer.
  /// Call once at startup so skills survive agent restarts without needing
  /// to re-register in the app.
  Future<void> loadCache() async {
    final skills = await listInstalledSkills();
    _cache.clear();
    for (final s in skills) {
      _cache[s.skillId] = s;
    }
    _log.info('SkillRegistry cache loaded: ${_cache.keys.toList()}');
  }

  // ──────────────────────────────────────────────────────────
  //  HELPERS
  // ──────────────────────────────────────────────────────────

  AtKey _metaKey(String skillId) => AtKey()
    ..key = 'skill_meta.$skillId'
    ..namespace = _namespace
    ..metadata = (Metadata()
      ..ttl = 0 // permanent
      ..ttr = -1);

  void _validate(SkillMetadata meta) {
    if (meta.skillId.isEmpty) {
      throw ArgumentError('skillId must not be empty');
    }
    if (meta.skillId.contains(':') ||
        meta.skillId.contains(' ') ||
        meta.skillId.contains('.')) {
      throw ArgumentError(
          'skillId "${meta.skillId}" contains invalid characters — use the short name only (e.g. "email"), not the full image name');
    }
    if (meta.trustScore < 0.0 || meta.trustScore > 1.0) {
      throw ArgumentError('trustScore must be between 0.0 and 1.0');
    }
    if (!meta.skillAtSign.startsWith('@')) {
      throw ArgumentError('skillAtSign must start with @');
    }
    if (meta.signatureHash.isEmpty) {
      throw ArgumentError('signatureHash must not be empty');
    }
  }
}
