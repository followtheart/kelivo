import 'package:flutter/foundation.dart';

import '../models/agent_skill.dart';
import '../services/agent_skills/skill_store.dart';

/// State management for Agent Skills.
///
/// Manages the lifecycle of skill discovery, activation, and per-assistant
/// binding. Follows the same Provider/ChangeNotifier pattern used by
/// [InstructionInjectionProvider] and [WorldBookProvider].
class AgentSkillProvider with ChangeNotifier {
  /// All discovered skill metadata (loaded at startup).
  List<AgentSkillMeta> _skills = const <AgentSkillMeta>[];

  /// Cache of fully-loaded skills (populated on activation).
  final Map<String, AgentSkill> _loadedSkills = <String, AgentSkill>{};

  /// Set of globally disabled skill names.
  Set<String> _disabledSkills = const <String>{};

  /// Per-assistant active skill bindings.
  Map<String, List<String>> _activeByAssistant =
      const <String, List<String>>{};

  bool _initialized = false;

  // ─── Getters ─────────────────────────────────────────────────────────────

  /// All discovered skills (unmodifiable).
  List<AgentSkillMeta> get skills =>
      List<AgentSkillMeta>.unmodifiable(_skills);

  /// Globally disabled skill names.
  Set<String> get disabledSkills => Set<String>.unmodifiable(_disabledSkills);

  /// Whether a specific skill is enabled (not in disabled set).
  bool isEnabled(String name) => !_disabledSkills.contains(name);

  /// Number of enabled skills.
  int get enabledCount =>
      _skills.where((s) => !_disabledSkills.contains(s.name)).length;

  /// Get active skill names for a given assistant.
  List<String> activeSkillNamesFor(String? assistantId) {
    final key = _assistantKey(assistantId);
    if (_activeByAssistant.containsKey(key)) {
      return List<String>.unmodifiable(_activeByAssistant[key]!);
    }
    // Fallback to global
    final fallback = _activeByAssistant[_globalKey];
    if (fallback != null) return List<String>.unmodifiable(fallback);
    return const <String>[];
  }

  /// Check whether a skill is actively bound to a given assistant.
  bool isActiveFor(String name, {String? assistantId}) {
    return activeSkillNamesFor(assistantId).contains(name);
  }

  /// Get enabled skills available for a given assistant.
  ///
  /// Returns skills that are both:
  /// 1. Not globally disabled
  /// 2. Bound (active) for the given assistant
  List<AgentSkillMeta> boundSkillsFor(String? assistantId) {
    final activeNames = activeSkillNamesFor(assistantId).toSet();
    return _skills
        .where(
          (s) =>
              !_disabledSkills.contains(s.name) &&
              activeNames.contains(s.name),
        )
        .toList(growable: false);
  }

  /// Get a cached full skill if previously activated.
  AgentSkill? getCachedSkill(String name) => _loadedSkills[name];

  // ─── Initialization ──────────────────────────────────────────────────────

  /// Initialize: ensure default directory, scan for skills, load config.
  Future<void> initialize() async {
    if (_initialized) return;
    await AgentSkillStore.ensureDefaultDirectoryExists();
    await loadAll();
    _initialized = true;
  }

  /// Reload all skills and configuration from disk/prefs.
  Future<void> loadAll() async {
    try {
      _skills = await AgentSkillStore.discoverAll();
      _disabledSkills = await AgentSkillStore.getDisabledSkills();
      _activeByAssistant = await AgentSkillStore.getActiveByAssistant();
      notifyListeners();
    } catch (e) {
      debugPrint('AgentSkillProvider: Failed to load: $e');
      _skills = const <AgentSkillMeta>[];
      _disabledSkills = const <String>{};
      _activeByAssistant = const <String, List<String>>{};
      notifyListeners();
    }
  }

  /// Refresh: re-scan directories and reload configuration.
  Future<void> refresh() async {
    AgentSkillStore.clearCaches();
    _loadedSkills.clear();
    _initialized = false;
    await initialize();
  }

  // ─── Activation ──────────────────────────────────────────────────────────

  /// Activate a skill by loading its full content.
  ///
  /// Returns the loaded [AgentSkill] or `null` if loading failed.
  /// Results are cached in memory for the session.
  Future<AgentSkill?> activate(String name) async {
    // Return from cache if already loaded
    if (_loadedSkills.containsKey(name)) return _loadedSkills[name];

    // Find the metadata to get the directory path
    final meta = _skills.where((s) => s.name == name).firstOrNull;
    if (meta == null) return null;

    final skill = await AgentSkillStore.loadFull(meta.directoryPath);
    if (skill != null) {
      _loadedSkills[name] = skill;
    }
    return skill;
  }

  // ─── Enable/Disable ─────────────────────────────────────────────────────

  /// Toggle a skill's global enabled/disabled state.
  Future<void> toggleSkill(String name, {required bool enabled}) async {
    if (enabled) {
      _disabledSkills.remove(name);
    } else {
      _disabledSkills = Set<String>.from(_disabledSkills)..add(name);
    }
    await AgentSkillStore.setDisabledSkills(_disabledSkills);
    notifyListeners();
  }

  // ─── Per-Assistant Binding ───────────────────────────────────────────────

  /// Set active skills for a given assistant.
  Future<void> setActiveForAssistant(
    String? assistantId,
    List<String> names,
  ) async {
    final key = _assistantKey(assistantId);
    _activeByAssistant = Map<String, List<String>>.from(_activeByAssistant);
    _activeByAssistant[key] = names.toSet().toList(growable: false);
    await AgentSkillStore.setActiveSkillsForAssistant(assistantId, names);
    notifyListeners();
  }

  /// Toggle a single skill's binding for a given assistant.
  Future<void> toggleActiveForAssistant(
    String name, {
    required String? assistantId,
    required bool active,
  }) async {
    final current = List<String>.from(activeSkillNamesFor(assistantId));
    if (active) {
      if (!current.contains(name)) current.add(name);
    } else {
      current.remove(name);
    }
    await setActiveForAssistant(assistantId, current);
  }

  // ─── Search Directories ─────────────────────────────────────────────────

  /// Get all configured search directories.
  Future<List<String>> getSearchDirectories() async {
    return AgentSkillStore.getSearchDirectories();
  }

  /// Add a search directory. Returns `true` if added.
  Future<bool> addSearchDirectory(String path) async {
    final added = await AgentSkillStore.addSearchDirectory(path);
    if (added) await refresh();
    return added;
  }

  /// Remove a search directory. Returns `true` if removed.
  Future<bool> removeSearchDirectory(String path) async {
    final removed = await AgentSkillStore.removeSearchDirectory(path);
    if (removed) await refresh();
    return removed;
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  static const String _globalKey = '__global__';

  static String _assistantKey(String? assistantId) {
    final id = (assistantId ?? '').trim();
    return id.isEmpty ? _globalKey : id;
  }
}
