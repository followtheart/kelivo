import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/agent_skill.dart';
import '../../../utils/app_directories.dart';
import 'skill_parser.dart';

/// Discovers, loads, and persists Agent Skills configuration.
///
/// Skills are discovered by scanning configured directories for subdirectories
/// that contain a valid `SKILL.md` file.
///
/// Persistence uses [SharedPreferences] for:
/// - Custom search directory list
/// - Disabled skill names
/// - Per-assistant active skill bindings
class AgentSkillStore {
  AgentSkillStore._();

  // ─── Preference keys ────────────────────────────────────────────────────
  static const String _searchDirsKey = 'agent_skills_search_dirs_v1';
  static const String _disabledKey = 'agent_skills_disabled_v1';
  static const String _activeByAssistantKey = 'agent_skills_active_by_assistant_v1';
  static const String _defaultAssistantKey = '__global__';

  // ─── In-memory caches ───────────────────────────────────────────────────
  static List<String>? _searchDirsCache;
  static Set<String>? _disabledCache;
  static Map<String, List<String>>? _activeByAssistantCache;

  // ═══════════════════════════════════════════════════════════════════════════
  // Discovery
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns the default skills directory for the current platform.
  static Future<String> getDefaultSkillsDirectory() async {
    final appDir = await AppDirectories.getAppDataDirectory();
    return p.join(appDir.path, 'skills');
  }

  /// Returns well-known skills directories that may exist on the system.
  ///
  /// These are automatically included in the search path when they exist:
  /// - `~/.copilot/skills` — VS Code Copilot / Claude Code skills
  /// - `%APPDATA%/.copilot/skills` — Windows AppData variant
  /// - Kelivo's own default skills directory
  static Future<List<String>> getWellKnownDirectories() async {
    final dirs = <String>[];

    // 1. Kelivo's own default directory (always first)
    dirs.add(await getDefaultSkillsDirectory());

    // 2. ~/.copilot/skills and %APPDATA%/.copilot/skills
    final candidates = <String>[];
    try {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      if (home.isNotEmpty) {
        candidates.add(p.join(home, '.copilot', 'skills'));
      }
      // Windows: also check %APPDATA%/.copilot/skills
      final appData = Platform.environment['APPDATA'] ?? '';
      if (appData.isNotEmpty) {
        candidates.add(p.join(appData, '.copilot', 'skills'));
      }
    } catch (_) {}

    final seen = <String>{...dirs};
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && seen.add(candidate)) {
        try {
          if (await Directory(candidate).exists()) {
            dirs.add(candidate);
          }
        } catch (_) {}
      }
    }

    return dirs;
  }

  /// Discover all valid skills across all configured search directories.
  ///
  /// Returns metadata-only [AgentSkillMeta] objects for fast startup.
  static Future<List<AgentSkillMeta>> discoverAll() async {
    final dirs = await getSearchDirectories();
    final skills = <AgentSkillMeta>[];
    final seenNames = <String>{};

    for (final dirPath in dirs) {
      try {
        final dir = Directory(dirPath);
        if (!await dir.exists()) continue;

        await for (final entity in dir.list(followLinks: true)) {
          if (entity is! Directory) continue;
          final skillMdPath = p.join(entity.path, 'SKILL.md');
          final skillMdFile = File(skillMdPath);
          if (!await skillMdFile.exists()) continue;

          try {
            final content = await skillMdFile.readAsString();
            final meta = SkillParser.parseMetadata(content, entity.path);
            if (meta != null && !seenNames.contains(meta.name)) {
              // Validate that directory name matches skill name
              final dirName = p.basename(entity.path);
              if (dirName == meta.name) {
                seenNames.add(meta.name);
                skills.add(meta);
              } else {
                debugPrint(
                  'AgentSkillStore: Skipping skill at ${entity.path} '
                  '– directory name "$dirName" does not match skill name "${meta.name}"',
                );
              }
            }
          } catch (e) {
            debugPrint('AgentSkillStore: Error parsing ${entity.path}: $e');
          }
        }
      } catch (e) {
        debugPrint('AgentSkillStore: Error scanning directory $dirPath: $e');
      }
    }

    return skills;
  }

  /// Load full skill content for activation.
  ///
  /// Returns `null` if the skill directory or SKILL.md is invalid.
  static Future<AgentSkill?> loadFull(String directoryPath) async {
    try {
      final skillMdFile = File(p.join(directoryPath, 'SKILL.md'));
      if (!await skillMdFile.exists()) return null;
      final content = await skillMdFile.readAsString();
      return SkillParser.parseFull(content, directoryPath);
    } catch (e) {
      debugPrint('AgentSkillStore: Error loading full skill at $directoryPath: $e');
      return null;
    }
  }

  /// Read a resource file relative to a skill directory.
  ///
  /// Returns `null` if the file does not exist or the path escapes the skill
  /// directory (security: prevents path traversal).
  static Future<String?> readResource(
    String skillDirectoryPath,
    String relativePath,
  ) async {
    try {
      final resolved = p.normalize(p.join(skillDirectoryPath, relativePath));
      // Security: ensure resolved path is still under the skill directory
      if (!p.isWithin(skillDirectoryPath, resolved)) {
        debugPrint(
          'AgentSkillStore: Path traversal blocked for "$relativePath" '
          'under "$skillDirectoryPath"',
        );
        return null;
      }
      final file = File(resolved);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      debugPrint('AgentSkillStore: Error reading resource: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Search Directories
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get list of directories to scan for skills.
  ///
  /// Always includes well-known directories (Kelivo default, ~/.copilot/skills
  /// if it exists). User-added directories are appended after.
  static Future<List<String>> getSearchDirectories() async {
    if (_searchDirsCache != null) return List<String>.from(_searchDirsCache!);

    final wellKnown = await getWellKnownDirectories();
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_searchDirsKey);

    final userDirs = <String>[];
    if (json != null && json.isNotEmpty) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is List) {
          userDirs.addAll(decoded.map((e) => e.toString()));
        }
      } catch (_) {}
    }

    // Well-known dirs first, then user dirs, deduplicated
    final seen = <String>{};
    final allDirs = <String>[];
    for (final d in [...wellKnown, ...userDirs]) {
      if (d.isNotEmpty && seen.add(d)) {
        allDirs.add(d);
      }
    }

    _searchDirsCache = allDirs;
    return List<String>.from(allDirs);
  }

  /// Set the user-customized search directories.
  ///
  /// The default skills directory is always implicitly included and should
  /// not be in this list.
  static Future<void> setSearchDirectories(List<String> paths) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = paths
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    await prefs.setString(_searchDirsKey, jsonEncode(cleaned));
    _searchDirsCache = null; // invalidate cache
  }

  /// Add a single directory to the search path. Returns `true` if added.
  static Future<bool> addSearchDirectory(String path) async {
    final dirs = await getSearchDirectories();
    final normalized = path.trim();
    if (normalized.isEmpty) return false;
    if (dirs.contains(normalized)) return false;
    // User dirs = all dirs minus well-known ones
    final wellKnown = (await getWellKnownDirectories()).toSet();
    final userDirs = dirs.where((d) => !wellKnown.contains(d)).toList();
    userDirs.add(normalized);
    await setSearchDirectories(userDirs);
    return true;
  }

  /// Remove a single directory from the search path. Returns `true` if removed.
  ///
  /// Well-known directories (default, ~/.copilot/skills) cannot be removed.
  static Future<bool> removeSearchDirectory(String path) async {
    final wellKnown = (await getWellKnownDirectories()).toSet();
    if (wellKnown.contains(path)) return false; // cannot remove well-known
    final dirs = await getSearchDirectories();
    final userDirs = dirs.where((d) => d != path && !wellKnown.contains(d)).toList();
    await setSearchDirectories(userDirs);
    return true;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Disabled Skills
  // ═══════════════════════════════════════════════════════════════════════════

  /// Get the set of globally disabled skill names.
  static Future<Set<String>> getDisabledSkills() async {
    if (_disabledCache != null) return Set<String>.from(_disabledCache!);

    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_disabledKey);
    final result = <String>{};
    if (json != null && json.isNotEmpty) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is List) {
          result.addAll(decoded.map((e) => e.toString()));
        }
      } catch (_) {}
    }
    _disabledCache = result;
    return Set<String>.from(result);
  }

  /// Set the disabled skill names.
  static Future<void> setDisabledSkills(Set<String> names) async {
    _disabledCache = Set<String>.from(names);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_disabledKey, jsonEncode(names.toList()));
  }

  /// Toggle a single skill's disabled state.
  static Future<void> toggleDisabled(String name, {required bool disabled}) async {
    final current = await getDisabledSkills();
    if (disabled) {
      current.add(name);
    } else {
      current.remove(name);
    }
    await setDisabledSkills(current);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Per-Assistant Active Skills
  // ═══════════════════════════════════════════════════════════════════════════

  static String _assistantKey(String? assistantId) {
    final id = (assistantId ?? '').trim();
    return id.isEmpty ? _defaultAssistantKey : id;
  }

  /// Get the list of active skill names for a given assistant.
  ///
  /// Falls back to the global default if no per-assistant config exists.
  static Future<List<String>> getActiveSkillsForAssistant(
    String? assistantId,
  ) async {
    final map = await _loadActiveMap();
    final key = _assistantKey(assistantId);
    if (map.containsKey(key)) {
      return List<String>.from(map[key]!);
    }
    // Fallback to global
    final fallback = map[_defaultAssistantKey];
    if (fallback != null) return List<String>.from(fallback);
    return const <String>[];
  }

  /// Set active skill names for a given assistant.
  static Future<void> setActiveSkillsForAssistant(
    String? assistantId,
    List<String> names,
  ) async {
    final map = await _loadActiveMap();
    final key = _assistantKey(assistantId);
    map[key] = names.toSet().toList(growable: false);
    await _persistActiveMap(map);
  }

  /// Get the full per-assistant active skills map.
  static Future<Map<String, List<String>>> getActiveByAssistant() async {
    final map = await _loadActiveMap();
    return {for (final e in map.entries) e.key: List<String>.from(e.value)};
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Ensure default directory exists
  // ═══════════════════════════════════════════════════════════════════════════

  /// Ensure the default skills directory exists on disk.
  static Future<void> ensureDefaultDirectoryExists() async {
    try {
      final defaultDir = await getDefaultSkillsDirectory();
      final dir = Directory(defaultDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      debugPrint('AgentSkillStore: Failed to create default skills directory: $e');
    }
  }

  // ─── Internal persistence helpers ─────────────────────────────────────

  static Future<Map<String, List<String>>> _loadActiveMap() async {
    if (_activeByAssistantCache != null) {
      return {
        for (final e in _activeByAssistantCache!.entries)
          e.key: List<String>.from(e.value),
      };
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_activeByAssistantKey);
    final map = <String, List<String>>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map;
        decoded.forEach((key, value) {
          final list = (value is List)
              ? value.map((e) => e.toString()).toList(growable: false)
              : const <String>[];
          map[key.toString()] = list;
        });
      } catch (_) {}
    }
    _activeByAssistantCache = map;
    return {for (final e in map.entries) e.key: List<String>.from(e.value)};
  }

  static Future<void> _persistActiveMap(Map<String, List<String>> map) async {
    _activeByAssistantCache = {
      for (final e in map.entries) e.key: List<String>.from(e.value),
    };
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_activeByAssistantKey, jsonEncode(map));
    } catch (_) {}
  }

  /// Clear all caches (useful for testing or reset).
  static void clearCaches() {
    _searchDirsCache = null;
    _disabledCache = null;
    _activeByAssistantCache = null;
  }
}
