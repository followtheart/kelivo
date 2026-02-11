import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import '../models/memory.dart';

/// Persistent storage for memories using SQLite.
///
/// All CRUD methods are synchronous (SQLite via FFI). The [initialize] method
/// is async because it needs to resolve the application documents directory and
/// run the one-time SharedPreferences → SQLite migration.
class MemoryStore {
  static Database? _db;

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Initialize the SQLite database. Must be called once before any CRUD
  /// operations (typically in [main] after [WidgetsFlutterBinding.ensureInitialized]).
  static Future<void> initialize() async {
    if (_db != null) return;
    if (kIsWeb) return; // sqlite3 FFI is not available on web

    try {
      // On older Android versions the temp directory needs to be configured
      // before opening any database.
      if (!kIsWeb && Platform.isAndroid) {
        await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
      }

      final dir = await getApplicationDocumentsDirectory();
      final dbPath = p.join(dir.path, 'kelivo_memories.db');
      _db = sqlite3.open(dbPath);
      _db!.execute('PRAGMA journal_mode=WAL');
      _createTables();
      _backfillFts();

      // Lifecycle maintenance: purge expired, decay low-importance, etc.
      runLifecycleMaintenance();

      // One-time migration from the legacy SharedPreferences store.
      await _migrateFromSharedPrefs();
    } catch (e) {
      debugPrint('MemoryStore: initialisation failed – $e');
    }
  }

  static void _createTables() {
    _db!.execute('''
      CREATE TABLE IF NOT EXISTS memories (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        scope         TEXT    NOT NULL DEFAULT 'assistant',
        assistant_id  TEXT,
        category      TEXT    NOT NULL DEFAULT 'custom',
        content       TEXT    NOT NULL,
        source        TEXT    NOT NULL DEFAULT 'ai_tool',
        importance    INTEGER NOT NULL DEFAULT 3,
        concepts      TEXT,
        related_conversation_id TEXT,
        is_private    INTEGER NOT NULL DEFAULT 0,
        created_at    INTEGER NOT NULL,
        updated_at    INTEGER NOT NULL,
        expires_at    INTEGER,
        version       INTEGER NOT NULL DEFAULT 1
      )
    ''');
    _db!.execute('CREATE INDEX IF NOT EXISTS idx_memories_scope ON memories(scope)');
    _db!.execute('CREATE INDEX IF NOT EXISTS idx_memories_assistant ON memories(assistant_id)');
    _db!.execute('CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category)');
    _db!.execute('CREATE INDEX IF NOT EXISTS idx_memories_importance ON memories(importance DESC)');
    _db!.execute('CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at DESC)');
    _db!.execute('CREATE INDEX IF NOT EXISTS idx_memories_expires ON memories(expires_at)');

    // ── FTS5 full-text search virtual table ──
    _db!.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
        content,
        concepts,
        content='memories',
        content_rowid='id'
      )
    ''');

    // Triggers to keep FTS index in sync with the memories table.
    // Guard with a temp check so we don't fail on duplicate trigger names.
    _execIgnore('''
      CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
        INSERT INTO memories_fts(rowid, content, concepts)
        VALUES (new.id, new.content, new.concepts);
      END
    ''');
    _execIgnore('''
      CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, content, concepts)
        VALUES ('delete', old.id, old.content, old.concepts);
        INSERT INTO memories_fts(rowid, content, concepts)
        VALUES (new.id, new.content, new.concepts);
      END
    ''');
    _execIgnore('''
      CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, content, concepts)
        VALUES ('delete', old.id, old.content, old.concepts);
      END
    ''');
  }

  /// Execute SQL, ignoring errors (e.g. "trigger already exists").
  static void _execIgnore(String sql) {
    try {
      _db!.execute(sql);
    } catch (_) {
      // already exists – OK
    }
  }

  /// Backfill FTS index for any rows not yet indexed.
  /// Runs once per init; very fast if everything is already indexed.
  static void _backfillFts() {
    try {
      // Insert any memories rows whose rowid is missing from the FTS table.
      _db!.execute('''
        INSERT OR IGNORE INTO memories_fts(rowid, content, concepts)
        SELECT id, content, concepts FROM memories
        WHERE id NOT IN (SELECT rowid FROM memories_fts)
      ''');
    } catch (e) {
      debugPrint('MemoryStore: FTS backfill error – $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Legacy migration (SharedPreferences → SQLite, one-time)
  // ---------------------------------------------------------------------------

  static Future<void> _migrateFromSharedPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('memory_migrated_to_sqlite_v1') == true) return;

      final raw = prefs.getString('assistant_memories_v1');
      if (raw != null && raw.isNotEmpty) {
        final arr = jsonDecode(raw) as List<dynamic>;
        final now = DateTime.now().millisecondsSinceEpoch;
        final stmt = _db!.prepare('''
          INSERT INTO memories
            (scope, assistant_id, category, content, source,
             importance, concepts, is_private, created_at, updated_at, version)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''');
        for (final e in arr) {
          if (e is! Map) continue;
          final map = e is Map<String, dynamic>
              ? e
              : (e as Map).cast<String, dynamic>();
          final assistantId = (map['assistantId'] ?? '').toString();
          final content = (map['content'] ?? '').toString();
          if (content.isEmpty) continue;
          stmt.execute([
            'assistant', // scope
            assistantId,
            'custom', // category – unknown for legacy data
            content,
            'ai_tool', // source
            3, // importance
            null, // concepts
            0, // is_private
            now,
            now,
            1, // version
          ]);
        }
        stmt.dispose();
        // Remove legacy data after successful migration.
        await prefs.remove('assistant_memories_v1');
      }
      await prefs.setBool('memory_migrated_to_sqlite_v1', true);
    } catch (e) {
      debugPrint('MemoryStore: legacy migration error – $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Row → Model conversion
  // ---------------------------------------------------------------------------

  static Memory _rowToMemory(Row row) {
    final conceptsRaw = row['concepts'] as String?;
    final concepts = (conceptsRaw != null && conceptsRaw.isNotEmpty)
        ? conceptsRaw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
        : <String>[];
    return Memory(
      id: row['id'] as int,
      scope: MemoryScope.fromDb(row['scope'] as String?),
      assistantId: row['assistant_id'] as String?,
      category: MemoryCategory.fromDb(row['category'] as String?),
      content: row['content'] as String,
      source: MemorySource.fromDb(row['source'] as String?),
      importance: (row['importance'] as int?) ?? 3,
      concepts: concepts,
      relatedConversationId: row['related_conversation_id'] as String?,
      isPrivate: (row['is_private'] as int?) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch((row['created_at'] as int?) ?? 0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch((row['updated_at'] as int?) ?? 0),
      expiresAt: row['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int)
          : null,
      version: (row['version'] as int?) ?? 1,
    );
  }

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  /// Return all memories ordered by most-recently-updated first.
  static List<Memory> getAll() {
    if (_db == null) return [];
    final result = _db!.select('SELECT * FROM memories ORDER BY updated_at DESC');
    return result.map(_rowToMemory).toList();
  }

  /// Return memories that belong to the given [assistantId].
  static List<Memory> getForAssistant(String assistantId) {
    if (_db == null) return [];
    final result = _db!.select(
      'SELECT * FROM memories WHERE assistant_id = ? ORDER BY importance DESC, updated_at DESC',
      [assistantId],
    );
    return result.map(_rowToMemory).toList();
  }

  /// Return a single memory by [id], or `null` if not found.
  static Memory? getById(int id) {
    if (_db == null) return null;
    final result = _db!.select('SELECT * FROM memories WHERE id = ?', [id]);
    if (result.isEmpty) return null;
    return _rowToMemory(result.first);
  }

  /// Insert a new memory and return it (with the auto-generated id).
  static Memory add({
    required String assistantId,
    required String content,
    MemoryScope scope = MemoryScope.assistant,
    MemoryCategory category = MemoryCategory.custom,
    MemorySource source = MemorySource.aiTool,
    int importance = 3,
    List<String>? concepts,
    String? relatedConversationId,
  }) {
    if (_db == null) {
      // Fallback – should not happen after proper init.
      final now = DateTime.now();
      return Memory(
        id: 0,
        scope: scope,
        assistantId: assistantId,
        category: category,
        content: content,
        source: source,
        importance: importance,
        concepts: concepts ?? [],
        createdAt: now,
        updatedAt: now,
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final conceptsStr = concepts?.where((s) => s.isNotEmpty).join(',');
    _db!.execute(
      '''INSERT INTO memories
           (scope, assistant_id, category, content, source,
            importance, concepts, related_conversation_id,
            is_private, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1)''',
      [
        scope == MemoryScope.global ? 'global' : 'assistant',
        scope == MemoryScope.global ? null : assistantId,
        category.dbValue,
        content,
        source.dbValue,
        importance.clamp(1, 5),
        conceptsStr,
        relatedConversationId,
        now,
        now,
      ],
    );
    final id = _db!.lastInsertRowId;
    return getById(id)!;
  }

  /// Update fields of an existing memory. Only non-null parameters are applied.
  /// Returns the updated [Memory] or `null` if [id] was not found.
  static Memory? update({
    required int id,
    String? content,
    MemoryCategory? category,
    int? importance,
    List<String>? concepts,
    bool? isPrivate,
  }) {
    if (_db == null) return null;
    final existing = getById(id);
    if (existing == null) return null;

    final sets = <String>[];
    final values = <Object?>[];

    if (content != null) {
      sets.add('content = ?');
      values.add(content);
    }
    if (category != null) {
      sets.add('category = ?');
      values.add(category.dbValue);
    }
    if (importance != null) {
      sets.add('importance = ?');
      values.add(importance.clamp(1, 5));
    }
    if (concepts != null) {
      sets.add('concepts = ?');
      values.add(concepts.where((s) => s.isNotEmpty).join(','));
    }
    if (isPrivate != null) {
      sets.add('is_private = ?');
      values.add(isPrivate ? 1 : 0);
    }
    if (sets.isEmpty) return existing;

    sets.add('updated_at = ?');
    values.add(DateTime.now().millisecondsSinceEpoch);
    sets.add('version = version + 1');

    values.add(id); // for WHERE clause

    _db!.execute(
      'UPDATE memories SET ${sets.join(', ')} WHERE id = ?',
      values,
    );
    return getById(id);
  }

  /// Delete a memory by [id]. Returns `true` if a row was actually removed.
  static bool delete(int id) {
    if (_db == null) return false;
    _db!.execute('DELETE FROM memories WHERE id = ?', [id]);
    return _db!.getUpdatedRows() > 0;
  }

  /// Return important memories for injection (importance >= [minImportance]).
  /// Combines global memories and assistant-specific memories.
  /// When [includeGlobal] is false, only assistant-scoped memories are returned.
  static List<Memory> getImportant({
    required String assistantId,
    int minImportance = 4,
    int limit = 30,
    bool includeGlobal = true,
  }) {
    if (_db == null) return [];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final String scopeCondition;
    final List<Object?> params;
    if (includeGlobal) {
      scopeCondition = "(scope = 'global' OR assistant_id = ?)";
      params = [minImportance, assistantId, nowMs, limit];
    } else {
      scopeCondition = 'assistant_id = ?';
      params = [minImportance, assistantId, nowMs, limit];
    }
    final result = _db!.select(
      '''SELECT * FROM memories
         WHERE importance >= ?
           AND $scopeCondition
           AND is_private = 0
           AND (expires_at IS NULL OR expires_at > ?)
         ORDER BY importance DESC, updated_at DESC
         LIMIT ?''',
      params,
    );
    return result.map(_rowToMemory).toList();
  }

  /// Search memories using FTS5 full-text search.
  /// Falls back to LIKE search for very short queries (< 2 chars) where FTS
  /// tokenisation may not produce useful results.
  static List<Memory> search({
    required String query,
    String? assistantId,
    MemoryCategory? category,
    String scope = 'all', // 'global', 'assistant', 'all'
    int limit = 10,
  }) {
    if (_db == null || query.trim().isEmpty) return [];

    final trimmed = query.trim();

    // For short queries (single CJK char or 1-char latin), FTS5 tokenisation
    // is unreliable — fall back to LIKE.
    final useFts = trimmed.length >= 2;

    if (useFts) {
      return _searchFts(
        query: trimmed,
        assistantId: assistantId,
        category: category,
        scope: scope,
        limit: limit,
      );
    }
    return _searchLike(
      query: trimmed,
      assistantId: assistantId,
      category: category,
      scope: scope,
      limit: limit,
    );
  }

  /// FTS5-backed search.  Joins memories_fts with memories to apply scope /
  /// category / privacy filters while ranking by FTS relevance.
  static List<Memory> _searchFts({
    required String query,
    String? assistantId,
    MemoryCategory? category,
    String scope = 'all',
    int limit = 10,
  }) {
    // Build FTS match expression.  Wrap each token with "*" for prefix match
    // so that partial words still hit.  Multiple tokens are OR-ed.
    final tokens = query
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"${t.replaceAll('"', '')}"*')
        .toList();
    if (tokens.isEmpty) return [];
    final matchExpr = tokens.join(' OR ');

    final conditions = <String>[];
    final params = <Object?>[];

    // Scope filtering
    if (scope == 'global') {
      conditions.add("m.scope = 'global'");
    } else if (scope == 'assistant' && assistantId != null) {
      conditions.add('m.assistant_id = ?');
      params.add(assistantId);
    } else if (scope == 'all' && assistantId != null) {
      conditions.add("(m.scope = 'global' OR m.assistant_id = ?)");
      params.add(assistantId);
    }

    if (category != null) {
      conditions.add('m.category = ?');
      params.add(category.dbValue);
    }

    conditions.add('m.is_private = 0');
    // Exclude expired memories
    conditions.add('(m.expires_at IS NULL OR m.expires_at > ?)');
    params.add(DateTime.now().millisecondsSinceEpoch);
    params.add(limit);

    final where = conditions.isNotEmpty ? 'AND ${conditions.join(' AND ')}' : '';

    try {
      final sql = '''
        SELECT m.* FROM memories_fts f
        JOIN memories m ON m.id = f.rowid
        WHERE memories_fts MATCH ?
        $where
        ORDER BY f.rank, m.importance DESC
        LIMIT ?
      ''';
      final result = _db!.select(sql, [matchExpr, ...params]);
      return result.map(_rowToMemory).toList();
    } catch (e) {
      // FTS match syntax error – fall back to LIKE.
      debugPrint('MemoryStore: FTS search error – $e, falling back to LIKE');
      return _searchLike(
        query: query,
        assistantId: assistantId,
        category: category,
        scope: scope,
        limit: limit,
      );
    }
  }

  /// Simple LIKE-based fallback search.
  static List<Memory> _searchLike({
    required String query,
    String? assistantId,
    MemoryCategory? category,
    String scope = 'all',
    int limit = 10,
  }) {
    final conditions = <String>[];
    final params = <Object?>[];

    final pattern = '%$query%';
    conditions.add('(content LIKE ? OR concepts LIKE ?)');
    params.addAll([pattern, pattern]);

    if (scope == 'global') {
      conditions.add("scope = 'global'");
    } else if (scope == 'assistant' && assistantId != null) {
      conditions.add('assistant_id = ?');
      params.add(assistantId);
    } else if (scope == 'all' && assistantId != null) {
      conditions.add("(scope = 'global' OR assistant_id = ?)");
      params.add(assistantId);
    }

    if (category != null) {
      conditions.add('category = ?');
      params.add(category.dbValue);
    }

    conditions.add('is_private = 0');
    // Exclude expired memories
    conditions.add('(expires_at IS NULL OR expires_at > ?)');
    params.add(DateTime.now().millisecondsSinceEpoch);
    params.add(limit);

    final sql =
        'SELECT * FROM memories WHERE ${conditions.join(' AND ')} ORDER BY importance DESC, updated_at DESC LIMIT ?';
    final result = _db!.select(sql, params);
    return result.map(_rowToMemory).toList();
  }

  /// Batch get memories by a list of [ids].
  static List<Memory> getByIds(List<int> ids) {
    if (_db == null || ids.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final result = _db!.select(
      'SELECT * FROM memories WHERE id IN ($placeholders) ORDER BY importance DESC',
      ids,
    );
    return result.map(_rowToMemory).toList();
  }

  /// Return the total count of non-private memories reachable by a given
  /// assistant (global + assistant-scoped, or assistant-only).
  static int countForAssistant(String assistantId, {bool includeGlobal = true}) {
    if (_db == null) return 0;
    final String condition;
    if (includeGlobal) {
      condition = "(scope = 'global' OR assistant_id = ?)";
    } else {
      condition = 'assistant_id = ?';
    }
    final result = _db!.select(
      'SELECT COUNT(*) AS cnt FROM memories WHERE is_private = 0 AND $condition',
      [assistantId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// Delete all memories belonging to the given [assistantId].
  static void deleteForAssistant(String assistantId) {
    if (_db == null) return;
    _db!.execute('DELETE FROM memories WHERE assistant_id = ?', [assistantId]);
  }

  /// Toggle the isPrivate flag on a memory.
  static Memory? setPrivate(int id, bool isPrivate) {
    return update(id: id, isPrivate: isPrivate);
  }

  /// Export all memories as a list of JSON-serializable maps.
  static List<Map<String, dynamic>> exportAll() {
    if (_db == null) return [];
    final all = getAll();
    return all.map((m) => m.toJson()).toList();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle Maintenance
  // ---------------------------------------------------------------------------

  /// Run all lifecycle maintenance tasks.
  /// Called once on startup; safe to call periodically.
  ///
  /// 1. Delete expired memories (expires_at <= now).
  /// 2. Decay importance for stale low-importance memories.
  /// 3. Delete memories whose importance has decayed to 0.
  static void runLifecycleMaintenance() {
    if (_db == null) return;
    try {
      _purgeExpired();
      _decayImportance();
      _deleteDecayed();
    } catch (e) {
      debugPrint('MemoryStore: lifecycle maintenance error – $e');
    }
  }

  /// Delete all memories whose expires_at is in the past.
  static void _purgeExpired() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _db!.execute(
      'DELETE FROM memories WHERE expires_at IS NOT NULL AND expires_at <= ?',
      [nowMs],
    );
    final purged = _db!.getUpdatedRows();
    if (purged > 0) {
      debugPrint('MemoryStore: purged $purged expired memories');
    }
  }

  /// Decay importance for memories that haven't been updated in a long time.
  ///
  /// Rules (from plan §7.1):
  /// - importance >= 4  → never auto-decayed.
  /// - importance <= 2  and unchanged for > 30 days → importance = importance - 1.
  /// - importance == 3  and unchanged for > 90 days → importance = importance - 1.
  static void _decayImportance() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const day30 = 30 * 24 * 60 * 60 * 1000;
    const day90 = 90 * 24 * 60 * 60 * 1000;

    // Low-importance (1-2) stale for >30 days: decay by 1.
    _db!.execute(
      '''UPDATE memories
         SET importance = importance - 1, updated_at = ?
         WHERE importance BETWEEN 1 AND 2
           AND updated_at < ?
           AND (expires_at IS NULL OR expires_at > ?)''',
      [nowMs, nowMs - day30, nowMs],
    );
    final decayed1 = _db!.getUpdatedRows();

    // Medium importance (3) stale for >90 days: decay by 1.
    _db!.execute(
      '''UPDATE memories
         SET importance = importance - 1, updated_at = ?
         WHERE importance = 3
           AND updated_at < ?
           AND (expires_at IS NULL OR expires_at > ?)''',
      [nowMs, nowMs - day90, nowMs],
    );
    final decayed3 = _db!.getUpdatedRows();

    if (decayed1 + decayed3 > 0) {
      debugPrint(
        'MemoryStore: decayed importance – '
        '${decayed1} low-imp, ${decayed3} mid-imp',
      );
    }
  }

  /// Delete memories whose importance has reached 0 (fully decayed).
  static void _deleteDecayed() {
    _db!.execute('DELETE FROM memories WHERE importance <= 0');
    final deleted = _db!.getUpdatedRows();
    if (deleted > 0) {
      debugPrint('MemoryStore: deleted $deleted fully-decayed memories');
    }
  }

  /// Close the database. Normally called only on app exit.
  static void dispose() {
    _db?.dispose();
    _db = null;
  }
}

