import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';

import '../../models/agent_skill.dart';

/// Parser for SKILL.md files following the Agent Skills specification.
///
/// Handles:
/// - YAML frontmatter extraction & parsing
/// - Name validation (lowercase alphanumeric + hyphens, 1-64 chars)
/// - Metadata-only parsing (for startup discovery) and full parsing (for activation)
class SkillParser {
  SkillParser._();

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Parse only frontmatter metadata from a SKILL.md file.
  ///
  /// Returns `null` if the content is invalid or missing required fields.
  /// [dirPath] is the absolute path of the skill directory.
  static AgentSkillMeta? parseMetadata(String skillMdContent, String dirPath) {
    final parts = _splitFrontmatter(skillMdContent);
    if (parts == null) return null;

    final yaml = _parseYaml(parts.frontmatter);
    if (yaml == null) return null;

    final name = _getString(yaml, 'name');
    final description = _getString(yaml, 'description');
    if (name == null || name.isEmpty || description == null || description.isEmpty) {
      return null;
    }
    if (!isValidName(name)) return null;

    return AgentSkillMeta(
      name: name,
      description: description,
      license: _getString(yaml, 'license'),
      compatibility: _getString(yaml, 'compatibility'),
      metadata: _parseMetadataMap(yaml['metadata']),
      allowedTools: _parseAllowedTools(yaml['allowed-tools']),
      directoryPath: dirPath,
    );
  }

  /// Parse full SKILL.md content (metadata + instruction body).
  ///
  /// Returns `null` if the content is invalid.
  /// Checks for optional resource directories under [dirPath].
  static AgentSkill? parseFull(String skillMdContent, String dirPath) {
    final meta = parseMetadata(skillMdContent, dirPath);
    if (meta == null) return null;

    final parts = _splitFrontmatter(skillMdContent);
    final body = (parts?.body ?? '').trim();

    // Detect optional directories
    bool hasScripts = false;
    bool hasReferences = false;
    bool hasAssets = false;
    try {
      hasScripts = Directory('$dirPath/scripts').existsSync();
      hasReferences = Directory('$dirPath/references').existsSync();
      hasAssets = Directory('$dirPath/assets').existsSync();
    } catch (_) {}

    return AgentSkill.fromMeta(
      meta,
      instructions: body,
      hasScripts: hasScripts,
      hasReferences: hasReferences,
      hasAssets: hasAssets,
    );
  }

  /// Validate a skill name according to the spec.
  ///
  /// Rules:
  /// - 1-64 characters
  /// - Only lowercase alphanumeric (`a-z`, `0-9`) and hyphens (`-`)
  /// - Must not start or end with `-`
  /// - Must not contain consecutive hyphens (`--`)
  static bool isValidName(String name) {
    if (name.isEmpty || name.length > 64) return false;
    if (name.startsWith('-') || name.endsWith('-')) return false;
    if (name.contains('--')) return false;
    return _namePattern.hasMatch(name);
  }

  /// Validate a SKILL.md content string and return a list of error messages.
  ///
  /// Returns an empty list if the content is valid.
  static List<String> validate(String skillMdContent) {
    final errors = <String>[];

    final parts = _splitFrontmatter(skillMdContent);
    if (parts == null) {
      errors.add('Missing or invalid YAML frontmatter (must start and end with ---)');
      return errors;
    }

    final yaml = _parseYaml(parts.frontmatter);
    if (yaml == null) {
      errors.add('Failed to parse YAML frontmatter');
      return errors;
    }

    // name
    final name = _getString(yaml, 'name');
    if (name == null || name.isEmpty) {
      errors.add('Missing required field: name');
    } else if (name.length > 64) {
      errors.add('name must be <= 64 characters (got ${name.length})');
    } else if (!isValidName(name)) {
      errors.add(
        'Invalid name "$name": must be lowercase alphanumeric + hyphens, '
        'no leading/trailing/consecutive hyphens',
      );
    }

    // description
    final description = _getString(yaml, 'description');
    if (description == null || description.isEmpty) {
      errors.add('Missing required field: description');
    } else if (description.length > 1024) {
      errors.add('description must be <= 1024 characters (got ${description.length})');
    }

    // compatibility
    final compat = _getString(yaml, 'compatibility');
    if (compat != null && compat.length > 500) {
      errors.add('compatibility must be <= 500 characters (got ${compat.length})');
    }

    return errors;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ──────────────────────────────────────────────────────────────────────────

  static final RegExp _namePattern = RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$');

  /// Split content into frontmatter (YAML between `---`) and body (rest).
  static _FrontmatterParts? _splitFrontmatter(String content) {
    final trimmed = content.trimLeft();
    if (!trimmed.startsWith('---')) return null;

    // Find closing ---
    final afterFirst = trimmed.indexOf('\n');
    if (afterFirst == -1) return null;

    final rest = trimmed.substring(afterFirst + 1);
    final closingIdx = rest.indexOf(RegExp(r'^---\s*$', multiLine: true));
    if (closingIdx == -1) return null;

    final frontmatter = rest.substring(0, closingIdx).trim();
    final afterClosing = rest.indexOf('\n', closingIdx);
    final body = afterClosing == -1 ? '' : rest.substring(afterClosing + 1);

    return _FrontmatterParts(frontmatter: frontmatter, body: body);
  }

  /// Parse YAML string into a map, returning null on failure.
  static Map<String, dynamic>? _parseYaml(String yamlStr) {
    try {
      final doc = loadYaml(yamlStr);
      if (doc is YamlMap) {
        return _yamlMapToMap(doc);
      }
      return null;
    } catch (e) {
      debugPrint('SkillParser: YAML parse error: $e');
      return null;
    }
  }

  /// Recursively convert `YamlMap` to `Map<String, dynamic>`.
  static Map<String, dynamic> _yamlMapToMap(YamlMap yamlMap) {
    final result = <String, dynamic>{};
    for (final entry in yamlMap.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (value is YamlMap) {
        result[key] = _yamlMapToMap(value);
      } else if (value is YamlList) {
        result[key] = value.toList();
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  static String? _getString(Map<String, dynamic> map, String key) {
    final val = map[key];
    if (val == null) return null;
    return val.toString().trim();
  }

  static Map<String, String> _parseMetadataMap(dynamic value) {
    if (value == null) return const <String, String>{};
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return const <String, String>{};
  }

  static List<String> _parseAllowedTools(dynamic value) {
    if (value == null) return const <String>[];
    if (value is List) {
      return value.map((e) => e.toString()).toList(growable: false);
    }
    // Spec says "space-delimited list"
    if (value is String) {
      return value
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }
}

/// Internal helper holding split frontmatter parts.
class _FrontmatterParts {
  final String frontmatter;
  final String body;
  const _FrontmatterParts({required this.frontmatter, required this.body});
}
