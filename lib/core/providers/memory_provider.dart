import 'package:flutter/foundation.dart';
import '../models/memory.dart';
import '../services/memory_store.dart';

class MemoryProvider extends ChangeNotifier {
  List<Memory> _memories = <Memory>[];
  bool _initialized = false;

  List<Memory> get memories => List.unmodifiable(_memories);

  List<Memory> getForAssistant(String assistantId) =>
      _memories.where((m) => m.assistantId == assistantId).toList();

  /// Return high-importance memories for auto-injection (Layer 1).
  List<Memory> getImportant({
    required String assistantId,
    int minImportance = 4,
    int limit = 30,
    bool includeGlobal = true,
  }) =>
      MemoryStore.getImportant(
        assistantId: assistantId,
        minImportance: minImportance,
        limit: limit,
        includeGlobal: includeGlobal,
      );

  /// Search memories by keyword, returning matching results (Layer 2).
  List<Memory> search({
    required String query,
    String? assistantId,
    MemoryCategory? category,
    String scope = 'all',
    int limit = 10,
  }) =>
      MemoryStore.search(
        query: query,
        assistantId: assistantId,
        category: category,
        scope: scope,
        limit: limit,
      );

  /// Batch-get memories by id list.
  List<Memory> getByIds(List<int> ids) => MemoryStore.getByIds(ids);

  /// Total count of accessible memories for [assistantId].
  int countForAssistant(String assistantId, {bool includeGlobal = true}) =>
      MemoryStore.countForAssistant(assistantId, includeGlobal: includeGlobal);

  Future<void> initialize() async {
    if (_initialized) return;
    loadAll();
    _initialized = true;
  }

  void loadAll() {
    try {
      _memories = MemoryStore.getAll();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load memories: $e');
      _memories = <Memory>[];
      notifyListeners();
    }
  }

  Future<Memory> add({
    required String assistantId,
    required String content,
    MemoryCategory category = MemoryCategory.custom,
    int importance = 3,
    List<String>? concepts,
    MemoryScope scope = MemoryScope.assistant,
    MemorySource source = MemorySource.aiTool,
  }) async {
    final mem = MemoryStore.add(
      assistantId: assistantId,
      content: content,
      scope: scope,
      category: category,
      source: source,
      importance: importance,
      concepts: concepts,
    );
    loadAll();
    return mem;
  }

  Future<Memory?> update({
    required int id,
    String? content,
    MemoryCategory? category,
    int? importance,
    List<String>? concepts,
    bool? isPrivate,
  }) async {
    final mem = MemoryStore.update(
      id: id,
      content: content,
      category: category,
      importance: importance,
      concepts: concepts,
      isPrivate: isPrivate,
    );
    loadAll();
    return mem;
  }

  Future<bool> delete({required int id}) async {
    final ok = MemoryStore.delete(id);
    loadAll();
    return ok;
  }

  /// Toggle isPrivate flag on a memory.
  Future<Memory?> setPrivate({required int id, required bool isPrivate}) async {
    final mem = MemoryStore.setPrivate(id, isPrivate);
    loadAll();
    return mem;
  }

  /// Export all memories as a JSON-serializable list.
  List<Map<String, dynamic>> exportAll() => MemoryStore.exportAll();
}

