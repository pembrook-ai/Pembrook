/// Skill metadata model.
///
/// Each installed skill has a metadata entry stored as:
///   skill_meta.$skillId.safeclaw@agent
///
/// The declared capabilities are enforced at TWO levels:
///   1. Application level: PolicyEngine rejects requests beyond declared scope
///   2. AtPlatform level: The skill's atSign can only access AtKeys that @agent
///      has explicitly shared with it — even malicious code cannot escape this.

/// What resources a skill is allowed to access.
class SkillCapabilities {
  /// AtKey namespace patterns the skill can read/write (e.g. ['calendar.*'])
  final List<String> atKeyNamespaces;

  /// Network endpoints the skill can reach (empty = --network=none)
  final List<String> networkEndpoints;

  /// Shell commands the skill may run (empty = none)
  final List<String> shellCommands;

  /// Filesystem paths the skill may access (empty = no filesystem access)
  final List<String> filesystemPaths;

  /// Action categories that require HITL before execution
  final List<String> hitlRequired;

  const SkillCapabilities({
    this.atKeyNamespaces = const [],
    this.networkEndpoints = const [],
    this.shellCommands = const [],
    this.filesystemPaths = const [],
    this.hitlRequired = const [],
  });

  Map<String, dynamic> toJson() => {
        'atKeyNamespaces': atKeyNamespaces,
        'networkEndpoints': networkEndpoints,
        'shellCommands': shellCommands,
        'filesystemPaths': filesystemPaths,
        'hitlRequired': hitlRequired,
      };

  factory SkillCapabilities.fromJson(Map<String, dynamic> json) =>
      SkillCapabilities(
        atKeyNamespaces:
            (json['atKeyNamespaces'] as List<dynamic>? ?? []).cast<String>(),
        networkEndpoints:
            (json['networkEndpoints'] as List<dynamic>? ?? []).cast<String>(),
        shellCommands:
            (json['shellCommands'] as List<dynamic>? ?? []).cast<String>(),
        filesystemPaths:
            (json['filesystemPaths'] as List<dynamic>? ?? []).cast<String>(),
        hitlRequired:
            (json['hitlRequired'] as List<dynamic>? ?? []).cast<String>(),
      );
}

/// An installed skill's registry entry.
class SkillMetadata {
  final String skillId;

  /// The skill's own atSign (dedicated, or @agent with skill namespace)
  final String skillAtSign;

  /// The developer's verified atSign (no anonymous publishing)
  final String developerAtSign;

  /// SHA-256 of the skill package at install time
  final String signatureHash;

  final String version;
  final SkillCapabilities declaredCapabilities;

  /// 0.0–1.0: computed from developer reputation + audit history
  final double trustScore;

  final DateTime installedAt;
  final String lastAuditResult; // 'clean' | 'warning' | 'failed'

  /// Owner's custom overrides for this skill (tighter than declared)
  final Map<String, dynamic> ownerPolicyOverrides;

  const SkillMetadata({
    required this.skillId,
    required this.skillAtSign,
    required this.developerAtSign,
    required this.signatureHash,
    required this.version,
    required this.declaredCapabilities,
    this.trustScore = 0.0,
    required this.installedAt,
    this.lastAuditResult = 'unknown',
    this.ownerPolicyOverrides = const {},
  });

  Map<String, dynamic> toJson() => {
        'skillId': skillId,
        'skillAtSign': skillAtSign,
        'developerAtSign': developerAtSign,
        'signatureHash': signatureHash,
        'version': version,
        'declaredCapabilities': declaredCapabilities.toJson(),
        'trustScore': trustScore,
        'installedAt': installedAt.toIso8601String(),
        'lastAuditResult': lastAuditResult,
        'ownerPolicyOverrides': ownerPolicyOverrides,
      };

  factory SkillMetadata.fromJson(Map<String, dynamic> json) => SkillMetadata(
        skillId: json['skillId'] as String,
        skillAtSign: json['skillAtSign'] as String,
        developerAtSign: json['developerAtSign'] as String,
        signatureHash: json['signatureHash'] as String,
        version: json['version'] as String,
        declaredCapabilities: SkillCapabilities.fromJson(
            json['declaredCapabilities'] as Map<String, dynamic>? ?? {}),
        trustScore: (json['trustScore'] as num?)?.toDouble() ?? 0.0,
        installedAt: DateTime.tryParse(json['installedAt'] as String? ?? '') ??
            DateTime.now(),
        lastAuditResult: json['lastAuditResult'] as String? ?? 'unknown',
        ownerPolicyOverrides:
            json['ownerPolicyOverrides'] as Map<String, dynamic>? ?? {},
      );
}
