/// Memory scope – global (shared across all assistants) or assistant-specific.
enum MemoryScope {
  global('global'),
  assistant('assistant');

  const MemoryScope(this.dbValue);
  final String dbValue;

  static MemoryScope fromDb(String? v) =>
      MemoryScope.values.firstWhere((e) => e.dbValue == v, orElse: () => MemoryScope.assistant);
}

/// Memory category for classification.
enum MemoryCategory {
  userProfile('user_profile'),
  preference('preference'),
  fact('fact'),
  task('task'),
  decision('decision'),
  learning('learning'),
  custom('custom');

  const MemoryCategory(this.dbValue);
  final String dbValue;

  static MemoryCategory fromDb(String? v) =>
      MemoryCategory.values.firstWhere((e) => e.dbValue == v, orElse: () => MemoryCategory.custom);
}

/// Memory source – how the memory was created.
enum MemorySource {
  aiAuto('ai_auto'),
  aiTool('ai_tool'),
  userManual('user_manual'),
  system('system');

  const MemorySource(this.dbValue);
  final String dbValue;

  static MemorySource fromDb(String? v) =>
      MemorySource.values.firstWhere((e) => e.dbValue == v, orElse: () => MemorySource.aiTool);
}

/// Represents a single persistent memory record.
class Memory {
  final int id;
  final MemoryScope scope;
  final String? assistantId;
  final MemoryCategory category;
  final String content;
  final MemorySource source;
  final int importance; // 1-5
  final List<String> concepts;
  final String? relatedConversationId;
  final bool isPrivate;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final int version;

  const Memory({
    this.id = 0,
    this.scope = MemoryScope.assistant,
    this.assistantId,
    this.category = MemoryCategory.custom,
    required this.content,
    this.source = MemorySource.aiTool,
    this.importance = 3,
    this.concepts = const [],
    this.relatedConversationId,
    this.isPrivate = false,
    required this.createdAt,
    required this.updatedAt,
    this.expiresAt,
    this.version = 1,
  });

  Memory copyWith({
    int? id,
    MemoryScope? scope,
    String? assistantId,
    MemoryCategory? category,
    String? content,
    MemorySource? source,
    int? importance,
    List<String>? concepts,
    String? relatedConversationId,
    bool? isPrivate,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? expiresAt,
    int? version,
  }) =>
      Memory(
        id: id ?? this.id,
        scope: scope ?? this.scope,
        assistantId: assistantId ?? this.assistantId,
        category: category ?? this.category,
        content: content ?? this.content,
        source: source ?? this.source,
        importance: importance ?? this.importance,
        concepts: concepts ?? this.concepts,
        relatedConversationId: relatedConversationId ?? this.relatedConversationId,
        isPrivate: isPrivate ?? this.isPrivate,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        version: version ?? this.version,
      );

  /// Convert to JSON map (for export/backup).
  Map<String, dynamic> toJson() => {
        'id': id,
        'scope': scope.dbValue,
        'assistantId': assistantId,
        'category': category.dbValue,
        'content': content,
        'source': source.dbValue,
        'importance': importance,
        'concepts': concepts,
        'relatedConversationId': relatedConversationId,
        'isPrivate': isPrivate,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'expiresAt': expiresAt?.toIso8601String(),
        'version': version,
      };

  static Memory fromJson(Map<String, dynamic> json) {
    final conceptsRaw = json['concepts'];
    final concepts = conceptsRaw is List
        ? conceptsRaw.map((e) => e.toString()).toList()
        : conceptsRaw is String
            ? conceptsRaw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
            : <String>[];
    return Memory(
      id: (json['id'] as num?)?.toInt() ?? 0,
      scope: MemoryScope.fromDb(json['scope'] as String?),
      assistantId: json['assistantId'] as String?,
      category: MemoryCategory.fromDb(json['category'] as String?),
      content: (json['content'] ?? '').toString(),
      source: MemorySource.fromDb(json['source'] as String?),
      importance: (json['importance'] as num?)?.toInt() ?? 3,
      concepts: concepts,
      relatedConversationId: json['relatedConversationId'] as String?,
      isPrivate: json['isPrivate'] == true,
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
      expiresAt: json['expiresAt'] != null ? DateTime.tryParse(json['expiresAt']) : null,
      version: (json['version'] as num?)?.toInt() ?? 1,
    );
  }
}
