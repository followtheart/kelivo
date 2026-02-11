import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/execution_plan.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/models/memory.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/mcp/mcp_tool_service.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/services/function_calling/function_router.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/services/agent_skills/skill_tool_service.dart';

/// 工具调用处理服务
///
/// 处理各类工具调用：
/// - MCP 工具
/// - Memory 工具 (create/edit/delete)
/// - Search 工具
class ToolHandlerService {
  ToolHandlerService({
    required this.contextProvider,
  });

  /// Build context (used for accessing providers)
  final BuildContext contextProvider;

  // ============================================================================
  // Tool Schema Sanitization
  // ============================================================================

  /// Sanitize/translate JSON Schema to each provider's accepted subset.
  ///
  /// Different providers (Google, OpenAI, Claude) have different requirements
  /// for tool parameter schemas. This method normalizes schemas to work across
  /// all providers.
  static Map<String, dynamic> sanitizeToolParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind kind,
  ) {
    Map<String, dynamic> clone = _deepCloneMap(schema);
    clone = _sanitizeNode(clone, kind) as Map<String, dynamic>;
    return clone;
  }

  static dynamic _sanitizeNode(dynamic node, ProviderKind kind) {
    if (node is List) {
      return node.map((e) => _sanitizeNode(e, kind)).toList();
    }
    if (node is! Map) return node;

    final m = Map<String, dynamic>.from(node);
    // Remove $schema as it's not needed for tool definitions
    m.remove(r'$schema');

    // Convert 'const' to 'enum' for compatibility
    if (m.containsKey('const')) {
      final v = m['const'];
      if (v is String || v is num || v is bool) {
        m['enum'] = [v];
      }
      m.remove('const');
    }

    // Flatten anyOf/oneOf/allOf to first variant for simplicity
    for (final key in ['anyOf', 'oneOf', 'allOf', 'any_of', 'one_of', 'all_of']) {
      if (m[key] is List && (m[key] as List).isNotEmpty) {
        final first = (m[key] as List).first;
        final flattened = _sanitizeNode(first, kind);
        m.remove(key);
        if (flattened is Map<String, dynamic>) {
          m
            ..remove('type')
            ..remove('properties')
            ..remove('items');
          m.addAll(flattened);
        }
      }
    }

    // Normalize type array to single type
    final t = m['type'];
    if (t is List && t.isNotEmpty) m['type'] = t.first.toString();

    // Normalize items array to single item
    final items = m['items'];
    if (items is List && items.isNotEmpty) m['items'] = items.first;
    if (m['items'] is Map) m['items'] = _sanitizeNode(m['items'], kind);

    // Recursively sanitize properties
    if (m['properties'] is Map) {
      final props = Map<String, dynamic>.from(m['properties']);
      final norm = <String, dynamic>{};
      props.forEach((k, v) {
        norm[k] = _sanitizeNode(v, kind);
      });
      m['properties'] = norm;
    }

    // Keep only allowed keys based on provider
    Set<String> allowed;
    switch (kind) {
      case ProviderKind.google:
        allowed = {'type', 'description', 'properties', 'required', 'items', 'enum'};
        break;
      case ProviderKind.openai:
      case ProviderKind.claude:
        allowed = {'type', 'description', 'properties', 'required', 'items', 'enum'};
        break;
    }
    m.removeWhere((k, v) => !allowed.contains(k));
    return m;
  }

  static Map<String, dynamic> _deepCloneMap(Map<String, dynamic> input) {
    return jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
  }

  // ============================================================================
  // Tool Definitions Builder
  // ============================================================================

  /// Build tool definitions for API call.
  ///
  /// Returns a list of tool definitions including:
  /// - Search tool (if enabled and model supports tools)
  /// - Memory tools (if assistant has memory enabled)
  /// - MCP tools (from selected servers for the assistant)
  List<Map<String, dynamic>> buildToolDefinitions(
    SettingsProvider settings,
    Assistant? assistant,
    String providerKey,
    String modelId,
    bool hasBuiltInSearch, {
    required bool Function(String providerKey, String modelId) isToolModel,
  }) {
    final List<Map<String, dynamic>> toolDefs = <Map<String, dynamic>>[];
    final supportsTools = isToolModel(providerKey, modelId);

    // Search tool (skip when Gemini built-in search is active)
    if (settings.searchEnabled && !hasBuiltInSearch && supportsTools) {
      toolDefs.add(SearchToolService.getToolDefinition());
    }

    // Memory tools
    if (assistant?.enableMemory == true && supportsTools) {
      toolDefs.addAll(_buildMemoryToolDefinitions());
    }

    // MCP tools
    final mcpTools = _buildMcpToolDefinitions(
      settings: settings,
      assistant: assistant,
      providerKey: providerKey,
      supportsTools: supportsTools,
    );
    toolDefs.addAll(mcpTools);

    // Local tools (from FunctionRouter)
    if (supportsTools) {
      try {
        final router = contextProvider.read<FunctionRouter>();
        final providerCfg = settings.getProviderConfig(providerKey);
        final providerKind = ProviderConfig.classify(
          providerCfg.id,
          explicitType: providerCfg.providerType,
        );
        final localTools = router.buildLocalToolDefinitions(
          providerKey: providerKey,
          providerKind: providerKind,
        );
        // Sanitize parameters for the target provider
        for (final lt in localTools) {
          final fn = lt['function'] as Map<String, dynamic>?;
          if (fn != null && fn['parameters'] is Map<String, dynamic>) {
            fn['parameters'] = sanitizeToolParametersForProvider(
              fn['parameters'] as Map<String, dynamic>,
              providerKind,
            );
          }
        }
        toolDefs.addAll(localTools);
      } catch (_) {
        // FunctionRouter may not be available in all contexts
      }
    }

    // Agent Skill tools (activate, read resource, run script)
    if (supportsTools) {
      try {
        final skillProvider = contextProvider.read<AgentSkillProvider>();
        final skillTools = AgentSkillToolService.buildToolDefinitions(skillProvider);
        // Sanitize parameters for the target provider
        final providerCfg = settings.getProviderConfig(providerKey);
        final providerKind = ProviderConfig.classify(
          providerCfg.id,
          explicitType: providerCfg.providerType,
        );
        for (final st in skillTools) {
          final fn = st['function'] as Map<String, dynamic>?;
          if (fn != null && fn['parameters'] is Map<String, dynamic>) {
            fn['parameters'] = sanitizeToolParametersForProvider(
              fn['parameters'] as Map<String, dynamic>,
              providerKind,
            );
          }
        }
        toolDefs.addAll(skillTools);
      } catch (_) {
        // AgentSkillProvider may not be available
      }
    }

    // Plan tool (allows the LLM to self-trigger planning)
    if (supportsTools && (assistant?.planMode ?? PlanMode.never) != PlanMode.never) {
      toolDefs.add(_buildPlanToolDefinition());
    }

    return toolDefs;
  }

  /// Build memory tool definitions (create/edit/delete).
  List<Map<String, dynamic>> _buildMemoryToolDefinitions() {
    return [
      {
        'type': 'function',
        'function': {
          'name': 'create_memory',
          'description': 'Create a new memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'content': {'type': 'string', 'description': 'The content of the memory record'},
              'category': {
                'type': 'string',
                'enum': ['user_profile', 'preference', 'fact', 'task', 'decision', 'learning', 'custom'],
                'description': 'Memory category. Default: custom'
              },
              'importance': {
                'type': 'integer',
                'description': 'Importance level 1-5. 5=critical user info, 1=trivial. Default: 3'
              },
              'concepts': {
                'type': 'string',
                'description': 'Comma-separated tags, e.g. "work,project,deadline"'
              },
              'scope': {
                'type': 'string',
                'enum': ['global', 'assistant'],
                'description': 'Scope: global (shared across all assistants) or assistant (this assistant only). Default: assistant'
              },
            },
            'required': ['content']
          }
        }
      },
      {
        'type': 'function',
        'function': {
          'name': 'edit_memory',
          'description': 'Update an existing memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {'type': 'integer', 'description': 'The id of the memory record'},
              'content': {'type': 'string', 'description': 'New content for the memory record'},
              'category': {
                'type': 'string',
                'enum': ['user_profile', 'preference', 'fact', 'task', 'decision', 'learning', 'custom'],
                'description': 'Updated category'
              },
              'importance': {
                'type': 'integer',
                'description': 'Updated importance level 1-5'
              },
              'concepts': {
                'type': 'string',
                'description': 'Updated comma-separated tags'
              },
            },
            'required': ['id']
          }
        }
      },
      {
        'type': 'function',
        'function': {
          'name': 'delete_memory',
          'description': 'Delete a memory record.',
          'parameters': {
            'type': 'object',
            'properties': {
              'id': {'type': 'integer', 'description': 'The id of the memory record'}
            },
            'required': ['id']
          }
        }
      },
      {
        'type': 'function',
        'function': {
          'name': 'search_memory',
          'description': 'Search memories by keyword. Returns a compact summary list (id + category + truncated content). Use this to find relevant memories before using get_memory for full content.',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': 'Search keywords'},
              'category': {
                'type': 'string',
                'enum': ['user_profile', 'preference', 'fact', 'task', 'decision', 'learning', 'custom'],
                'description': 'Filter by category'
              },
              'scope': {
                'type': 'string',
                'enum': ['global', 'assistant', 'all'],
                'description': 'Search scope. Default: all'
              },
              'limit': {
                'type': 'integer',
                'description': 'Max results to return. Default: 10'
              },
            },
            'required': ['query']
          }
        }
      },
      {
        'type': 'function',
        'function': {
          'name': 'get_memory',
          'description': 'Batch-get full memory content by ID list. Use after search_memory to retrieve details for specific memories.',
          'parameters': {
            'type': 'object',
            'properties': {
              'ids': {
                'type': 'array',
                'items': {'type': 'integer'},
                'description': 'List of memory IDs to retrieve'
              },
            },
            'required': ['ids']
          }
        }
      },
    ];
  }

  /// Build MCP tool definitions from connected servers.
  List<Map<String, dynamic>> _buildMcpToolDefinitions({
    required SettingsProvider settings,
    required Assistant? assistant,
    required String providerKey,
    required bool supportsTools,
  }) {
    if (!supportsTools) return [];

    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    final tools = toolSvc.listAvailableToolsForAssistant(
      mcp,
      contextProvider.read<AssistantProvider>(),
      assistant?.id,
    );

    if (tools.isEmpty) return [];

    final providerCfg = settings.getProviderConfig(providerKey);
    final providerKind = ProviderConfig.classify(
      providerCfg.id,
      explicitType: providerCfg.providerType,
    );

    return tools.map((t) {
      Map<String, dynamic> baseSchema;
      if (t.schema != null && t.schema!.isNotEmpty) {
        baseSchema = Map<String, dynamic>.from(t.schema!);
      } else {
        final props = <String, dynamic>{
          for (final p in t.params) p.name: {'type': (p.type ?? 'string')}
        };
        final required = [
          for (final p in t.params.where((e) => e.required)) p.name
        ];
        baseSchema = {
          'type': 'object',
          'properties': props,
          if (required.isNotEmpty) 'required': required
        };
      }
      final sanitized = sanitizeToolParametersForProvider(baseSchema, providerKind);
      return {
        'type': 'function',
        'function': {
          'name': t.name,
          if ((t.description ?? '').isNotEmpty) 'description': t.description,
          'parameters': sanitized,
        }
      };
    }).toList();
  }

  // ============================================================================
  // Tool Call Handler
  // ============================================================================

  /// Build tool call handler function.
  ///
  /// Returns a function that handles tool calls by name and arguments.
  /// Supports:
  /// - Search tool calls
  /// - Memory tool calls (create/edit/delete)
  /// - MCP tool calls
  Future<String> Function(String, Map<String, dynamic>)? buildToolCallHandler(
    SettingsProvider settings,
    Assistant? assistant,
  ) {
    final mcp = contextProvider.read<McpProvider>();
    final toolSvc = contextProvider.read<McpToolService>();
    // Capture AssistantProvider reference before async gap to avoid
    // use_build_context_synchronously warning
    final assistantProvider = contextProvider.read<AssistantProvider>();

    return (name, args) async {
      // Search tool
      if (name == SearchToolService.toolName && settings.searchEnabled) {
        final q = (args['query'] ?? '').toString();
        return await SearchToolService.executeSearch(q, settings);
      }

      // Memory tools
      final memoryResult = await _handleMemoryToolCall(name, args, assistant);
      if (memoryResult != null) {
        return memoryResult;
      }

      // Agent Skill tools
      if (AgentSkillToolService.isSkillTool(name)) {
        try {
          final skillProvider = contextProvider.read<AgentSkillProvider>();
          final result = await AgentSkillToolService.handleToolCall(
            name,
            args,
            skillProvider,
          );
          if (result != null) return result;
        } catch (e) {
          return 'Error: skill tool failed: $e';
        }
      }

      // Local tools (FunctionRouter)
      try {
        final router = contextProvider.read<FunctionRouter>();
        if (router.isToolRegistered(name)) {
          final result = await router.callTool(name, args);
          return result.toResponseText();
        }
      } catch (_) {
        // FunctionRouter may not be available
      }

      // MCP tools
      final text = await toolSvc.callToolTextForAssistant(
        mcp,
        assistantProvider,
        assistantId: assistant?.id,
        toolName: name,
        arguments: args,
      );
      return text;
    };
  }

  /// Build the "create_execution_plan" tool definition.
  static Map<String, dynamic> _buildPlanToolDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': 'create_execution_plan',
        'description':
            'When a task requires multiple coordinated steps to complete, '
            'create a structured execution plan. Use this for complex queries '
            'that involve calling multiple tools, comparing results, or '
            'aggregating data from several sources.',
        'parameters': {
          'type': 'object',
          'properties': {
            'goal': {
              'type': 'string',
              'description': 'A concise description of the task goal.',
            },
            'steps': {
              'type': 'array',
              'description': 'Ordered list of execution steps.',
              'items': {
                'type': 'object',
                'properties': {
                  'description': {
                    'type': 'string',
                    'description': 'Human-readable step description.',
                  },
                  'action': {
                    'type': 'string',
                    'enum': ['tool_call', 'llm_query', 'aggregate', 'validate'],
                    'description': 'The type of action for this step.',
                  },
                  'tool_name': {
                    'type': 'string',
                    'description': 'Tool name (only for tool_call action).',
                  },
                  'tool_args': {
                    'type': 'object',
                    'description': 'Arguments to pass to the tool.',
                  },
                  'depends_on': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description': 'List of step_ids this step depends on.',
                  },
                },
                'required': ['description'],
              },
            },
          },
          'required': ['goal', 'steps'],
        },
      },
    };
  }

  /// Infer [MemoryScope] from [MemoryCategory] when the AI omits scope.
  ///
  /// user_profile, fact, learning → global (shared across assistants).
  /// preference, task, decision, custom → assistant (scoped).
  static MemoryScope _inferScopeFromCategory(MemoryCategory category) {
    switch (category) {
      case MemoryCategory.userProfile:
      case MemoryCategory.fact:
      case MemoryCategory.learning:
        return MemoryScope.global;
      case MemoryCategory.preference:
      case MemoryCategory.task:
      case MemoryCategory.decision:
      case MemoryCategory.custom:
        return MemoryScope.assistant;
    }
  }

  /// Sensitive content blacklist — reject memory containing highly sensitive
  /// personal categories such as race, ethnicity, religion, political views,
  /// criminal records, medical diagnoses, sexual orientation, etc.
  static bool _containsSensitiveContent(String content) {
    // Patterns matching common sensitive categories (case-insensitive).
    // Intentionally broad to err on the side of privacy.
    const patterns = [
      // Race / ethnicity / nationality discrimination
      r'(?:种族|民族|族裔|race\b|ethnicity|ethnic)',
      // Religion
      r'(?:宗教|信仰|教派|religion|religious|faith\b)',
      // Political views
      r'(?:政治倾向|政党|political\s+(?:view|opinion|affiliation|party))',
      // Criminal records
      r'(?:犯罪记录|案底|前科|criminal\s+record|arrest record|conviction)',
      // Medical / health conditions
      r'(?:病历|诊断|HIV|艾滋|STD|性病|medical\s+diagnosis|health\s+condition)',
      // Sexual orientation / gender identity (when storing as a label)
      r'(?:性取向|sexual\s+orientation|gender\s+identity)',
      // Passwords / secrets
      r'(?:密码|password|secret\s+key|private\s+key|api[_\s]?key|access[_\s]?token)',
      // Financial (account / card numbers)
      r'(?:银行卡号|信用卡号|card\s+number|account\s+number|社保号|SSN|social\s+security)',
    ];
    final lower = content.toLowerCase();
    for (final p in patterns) {
      if (RegExp(p, caseSensitive: false).hasMatch(lower)) return true;
    }
    return false;
  }

  /// Handle memory tool calls (create/edit/delete).
  ///
  /// Returns null if the tool is not a memory tool or memory is not enabled.
  Future<String?> _handleMemoryToolCall(
    String name,
    Map<String, dynamic> args,
    Assistant? assistant,
  ) async {
    if (assistant?.enableMemory != true) return null;

    try {
      final mp = contextProvider.read<MemoryProvider>();

      if (name == 'create_memory') {
        final content = (args['content'] ?? '').toString();
        if (content.isEmpty) return '';

        // ── Sensitive content blacklist ──
        // Reject memory creation containing sensitive categories.
        if (_containsSensitiveContent(content)) {
          debugPrint('MemoryTool: blocked sensitive content from being stored');
          return '';
        }

        // Parse optional enhanced fields
        final categoryStr = args['category']?.toString();
        final category = categoryStr != null
            ? MemoryCategory.fromDb(categoryStr)
            : MemoryCategory.custom;
        final importanceRaw = args['importance'] as num?;
        final importance = importanceRaw != null
            ? importanceRaw.toInt().clamp(1, 5)
            : 3;
        final conceptsStr = args['concepts']?.toString();
        final concepts = conceptsStr != null
            ? conceptsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
            : <String>[];
        final scopeStr = args['scope']?.toString();
        // Auto scope inference: if scope not explicitly provided, infer from category.
        final MemoryScope scope;
        if (scopeStr != null) {
          scope = MemoryScope.fromDb(scopeStr);
        } else {
          // user_profile, fact, learning → global; others → assistant
          scope = _inferScopeFromCategory(category);
        }

        final m = await mp.add(
          assistantId: assistant!.id,
          content: content,
          category: category,
          importance: importance,
          concepts: concepts.isEmpty ? null : concepts,
          scope: scope,
        );
        return m.content;
      } else if (name == 'edit_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) return '';

        final content = args['content']?.toString();
        final categoryStr = args['category']?.toString();
        final category = categoryStr != null
            ? MemoryCategory.fromDb(categoryStr)
            : null;
        final importanceRaw = args['importance'] as num?;
        final importance = importanceRaw?.toInt().clamp(1, 5);
        final conceptsStr = args['concepts']?.toString();
        final concepts = conceptsStr != null
            ? conceptsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
            : null;

        if (content == null && category == null && importance == null && concepts == null) {
          return '';
        }

        final m = await mp.update(
          id: id,
          content: content,
          category: category,
          importance: importance,
          concepts: concepts,
        );
        return m?.content ?? '';
      } else if (name == 'delete_memory') {
        final id = (args['id'] as num?)?.toInt() ?? -1;
        if (id <= 0) return '';
        final ok = await mp.delete(id: id);
        return ok ? 'deleted' : '';
      } else if (name == 'search_memory') {
        final query = (args['query'] ?? '').toString();
        if (query.isEmpty) return '[]';

        final categoryStr = args['category']?.toString();
        final category = categoryStr != null
            ? MemoryCategory.fromDb(categoryStr)
            : null;
        final scopeStr = args['scope']?.toString() ?? 'all';
        final limitRaw = args['limit'] as num?;
        final limit = limitRaw?.toInt().clamp(1, 50) ?? 10;

        final results = mp.search(
          query: query,
          assistantId: assistant!.id,
          category: category,
          scope: scopeStr,
          limit: limit,
        );

        // Return compact summaries (low token cost)
        final sb = StringBuffer();
        sb.writeln('Found ${results.length} memories:');
        for (final m in results) {
          final preview = m.content.length > 80
              ? '${m.content.substring(0, 80)}...'
              : m.content;
          sb.writeln('[${m.id}] (${m.category.dbValue}, imp=${m.importance}) $preview');
        }
        return sb.toString();
      } else if (name == 'get_memory') {
        final idsRaw = args['ids'];
        final ids = <int>[];
        if (idsRaw is List) {
          for (final v in idsRaw) {
            final id = (v is num) ? v.toInt() : int.tryParse(v.toString());
            if (id != null && id > 0) ids.add(id);
          }
        }
        if (ids.isEmpty) return '[]';

        final results = mp.getByIds(ids);
        final sb = StringBuffer();
        for (final m in results) {
          sb.writeln('--- Memory #${m.id} ---');
          sb.writeln('category: ${m.category.dbValue}');
          sb.writeln('importance: ${m.importance}');
          if (m.concepts.isNotEmpty) {
            sb.writeln('concepts: ${m.concepts.join(', ')}');
          }
          sb.writeln('scope: ${m.scope.dbValue}');
          sb.writeln('content: ${m.content}');
          sb.writeln();
        }
        return sb.toString();
      }
    } catch (_) {
      // Ignore memory operation errors
    }

    return null;
  }
}
