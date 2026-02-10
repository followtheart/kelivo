/// Data models for Agent Skills.
///
/// Agent Skills follow the open specification at https://agentskills.io/specification
/// Each skill is a directory containing a `SKILL.md` file with YAML frontmatter
/// (metadata) and Markdown body (instructions).
///
/// Two-tier model:
/// - [AgentSkillMeta] – lightweight metadata loaded at startup (~100 tokens each)
/// - [AgentSkill] – full content loaded on activation (<5000 tokens recommended)
library;

/// Lightweight metadata parsed from SKILL.md frontmatter.
///
/// Loaded for all discovered skills at startup to keep context usage low.
class AgentSkillMeta {
  /// Unique identifier (1-64 chars, lowercase alphanumeric + hyphens).
  final String name;

  /// What the skill does and when to use it (1-1024 chars).
  final String description;

  /// Optional license name or reference.
  final String? license;

  /// Optional environment compatibility note (max 500 chars).
  final String? compatibility;

  /// Optional arbitrary key-value metadata.
  final Map<String, String> metadata;

  /// Optional pre-approved tool list (experimental).
  final List<String> allowedTools;

  /// Absolute path to the skill directory on disk.
  final String directoryPath;

  const AgentSkillMeta({
    required this.name,
    required this.description,
    this.license,
    this.compatibility,
    this.metadata = const <String, String>{},
    this.allowedTools = const <String>[],
    required this.directoryPath,
  });

  AgentSkillMeta copyWith({
    String? name,
    String? description,
    String? license,
    String? compatibility,
    Map<String, String>? metadata,
    List<String>? allowedTools,
    String? directoryPath,
  }) {
    return AgentSkillMeta(
      name: name ?? this.name,
      description: description ?? this.description,
      license: license ?? this.license,
      compatibility: compatibility ?? this.compatibility,
      metadata: metadata ?? this.metadata,
      allowedTools: allowedTools ?? this.allowedTools,
      directoryPath: directoryPath ?? this.directoryPath,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'description': description,
    if (license != null) 'license': license,
    if (compatibility != null) 'compatibility': compatibility,
    if (metadata.isNotEmpty) 'metadata': metadata,
    if (allowedTools.isNotEmpty) 'allowedTools': allowedTools,
    'directoryPath': directoryPath,
  };

  static AgentSkillMeta fromJson(Map<String, dynamic> json) {
    return AgentSkillMeta(
      name: (json['name'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      license: json['license'] as String?,
      compatibility: json['compatibility'] as String?,
      metadata: _parseStringMap(json['metadata']),
      allowedTools: _parseStringList(json['allowedTools']),
      directoryPath: (json['directoryPath'] as String?) ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSkillMeta &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          directoryPath == other.directoryPath;

  @override
  int get hashCode => Object.hash(name, directoryPath);

  @override
  String toString() => 'AgentSkillMeta(name: $name, dir: $directoryPath)';
}

/// Full skill content loaded on activation.
///
/// Extends [AgentSkillMeta] with the Markdown instruction body and
/// flags indicating which optional resource directories exist.
class AgentSkill extends AgentSkillMeta {
  /// Markdown instruction body from SKILL.md (after frontmatter).
  final String instructions;

  /// Whether the skill directory contains a `scripts/` subdirectory.
  final bool hasScripts;

  /// Whether the skill directory contains a `references/` subdirectory.
  final bool hasReferences;

  /// Whether the skill directory contains an `assets/` subdirectory.
  final bool hasAssets;

  const AgentSkill({
    required super.name,
    required super.description,
    super.license,
    super.compatibility,
    super.metadata,
    super.allowedTools,
    required super.directoryPath,
    required this.instructions,
    this.hasScripts = false,
    this.hasReferences = false,
    this.hasAssets = false,
  });

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...super.toJson(),
    'instructions': instructions,
    'hasScripts': hasScripts,
    'hasReferences': hasReferences,
    'hasAssets': hasAssets,
  };

  static AgentSkill fromMeta(
    AgentSkillMeta meta, {
    required String instructions,
    bool hasScripts = false,
    bool hasReferences = false,
    bool hasAssets = false,
  }) {
    return AgentSkill(
      name: meta.name,
      description: meta.description,
      license: meta.license,
      compatibility: meta.compatibility,
      metadata: meta.metadata,
      allowedTools: meta.allowedTools,
      directoryPath: meta.directoryPath,
      instructions: instructions,
      hasScripts: hasScripts,
      hasReferences: hasReferences,
      hasAssets: hasAssets,
    );
  }

  @override
  String toString() =>
      'AgentSkill(name: $name, instructions: ${instructions.length} chars)';
}

// ─── Helpers ────────────────────────────────────────────────────────────────

Map<String, String> _parseStringMap(dynamic value) {
  if (value == null) return const <String, String>{};
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v.toString()));
  }
  return const <String, String>{};
}

List<String> _parseStringList(dynamic value) {
  if (value == null) return const <String>[];
  if (value is List) {
    return value.map((e) => e.toString()).toList(growable: false);
  }
  if (value is String) {
    return value
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  return const <String>[];
}
