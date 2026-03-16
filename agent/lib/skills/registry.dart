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

    _log.info(
        'Skill installed: ${meta.skillId} (trust=${meta.trustScore.toStringAsFixed(2)})');
    return meta;
  }

  // ──────────────────────────────────────────────────────────
  //  REMOVE
  // ──────────────────────────────────────────────────────────

  Future<void> removeSkill(String skillId) async {
    await atClient.delete(_metaKey(skillId));
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
  //  LIST
  // ──────────────────────────────────────────────────────────

  Future<List<SkillMetadata>> listInstalledSkills() async {
    try {
      final allKeys = await atClient.getKeys(regex: r'^skill_meta\.');
      final result = <SkillMetadata>[];
      for (final keyStr in allKeys) {
        try {
          final atKey = AtKey.fromString(keyStr);
          final v = await atClient.get(
            atKey,
            getRequestOptions: GetRequestOptions()..useRemoteAtServer = true,
          );
          if (v.value != null) {
            result.add(SkillMetadata.fromJson(
                jsonDecode(v.value as String) as Map<String, dynamic>));
          }
        } catch (_) {}
      }
      return result;
    } catch (e) {
      _log.warning('listInstalledSkills error: $e');
      return [];
    }
  }

  // ──────────────────────────────────────────────────────────
  //  HELPERS
  // ──────────────────────────────────────────────────────────

  AtKey _metaKey(String skillId) => AtKey()
    ..key = 'skill_meta.$skillId'
    ..namespace = _namespace
    ..sharedWith = atClient.getCurrentAtSign()
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
