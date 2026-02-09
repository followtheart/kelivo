import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../providers/settings_provider.dart';
import 'models/models.dart';
import 'tool_registry.dart';
import 'execution_engine.dart';
import 'handlers/local_program_handler.dart';

/// 本地工具配置文件名
const _kLocalToolsFileName = 'local_tools.json';

/// 函数路由器 — 统一入口
///
/// 整合 ToolRegistry + ExecutionEngine + LocalProgramHandler，
/// 提供简洁的对外接口。
///
/// 支持从 JSON 文件注册本地工具（类似 MCP 协议）。
class FunctionRouter extends ChangeNotifier {
  late final ToolRegistry registry;
  late final ExecutionEngine engine;
  late final LocalProgramHandler _localHandler;

  /// 本地工具配置文件路径
  String? _localToolsConfigPath;

  FunctionRouter() {
    registry = ToolRegistry();
    engine = ExecutionEngine(registry: registry);
    _localHandler = LocalProgramHandler();
    _registerDefaultLocalTools();
  }

  // ============================================================================
  // 初始化
  // ============================================================================

  /// 注册默认本地工具
  void _registerDefaultLocalTools() {
    final defaultTools = LocalProgramHandler.getDefaultLocalTools();
    for (final def in defaultTools) {
      registry.register(def, _createLocalExecutor(def));
    }
  }

  /// 为本地工具创建执行器
  ToolExecutor _createLocalExecutor(ToolDefinition definition) {
    return (name, args, ctx) {
      return _localHandler.execute(
        name,
        args,
        ctx,
        executorConfig: definition.executorConfig,
      );
    };
  }

  // ============================================================================
  // JSON 工具注册协议
  // ============================================================================

  /// 从 JSON 文件加载本地工具配置
  ///
  /// 配置文件格式:
  /// ```json
  /// {
  ///   "version": "1.0",
  ///   "tools": [
  ///     {
  ///       "name": "open_notepad",
  ///       "description": "打开记事本",
  ///       "source": "local",
  ///       "priority": 15,
  ///       "safety": "safe",
  ///       "parameters": {
  ///         "type": "object",
  ///         "properties": {
  ///           "file": {
  ///             "type": "string",
  ///             "description": "要打开的文件"
  ///           }
  ///         }
  ///       },
  ///       "executor": {
  ///         "type": "local_program",
  ///         "mode": "launch",
  ///         "command": "notepad.exe",
  ///         "defaultArgs": []
  ///       }
  ///     }
  ///   ]
  /// }
  /// ```
  Future<int> loadFromJsonFile(String filePath) async {
    _localToolsConfigPath = filePath;
    final file = File(filePath);

    if (!await file.exists()) {
      debugPrint('[FunctionRouter] Config file not found: $filePath');
      return 0;
    }

    try {
      final content = await file.readAsString();
      return loadFromJsonString(content);
    } catch (e) {
      debugPrint('[FunctionRouter] Failed to load config: $e');
      return 0;
    }
  }

  /// 从 JSON 字符串加载工具配置
  int loadFromJsonString(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr);
      List<Map<String, dynamic>> toolConfigs;

      if (data is Map<String, dynamic>) {
        // 带版本号的完整格式: { "version": "1.0", "tools": [...] }
        toolConfigs = (data['tools'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [];
      } else if (data is List) {
        // 简化格式: 直接是工具列表 [...]
        toolConfigs = data.cast<Map<String, dynamic>>();
      } else {
        debugPrint('[FunctionRouter] Invalid JSON format');
        return 0;
      }

      return loadFromJsonList(toolConfigs);
    } catch (e) {
      debugPrint('[FunctionRouter] Failed to parse JSON: $e');
      return 0;
    }
  }

  /// 从 JSON 列表加载工具配置
  int loadFromJsonList(List<Map<String, dynamic>> toolConfigs) {
    int count = 0;
    for (final json in toolConfigs) {
      try {
        final def = ToolDefinition.fromJson(json);

        // 根据 executor type 选择执行器
        final executorType =
            (def.executorConfig?['type'] ?? '').toString();

        ToolExecutor executor;
        switch (executorType) {
          case 'local_program':
            executor = _createLocalExecutor(def);
            break;
          default:
            debugPrint(
              '[FunctionRouter] Unknown executor type "$executorType" '
              'for tool "${def.name}", using local_program as fallback',
            );
            executor = _createLocalExecutor(def);
        }

        registry.register(def, executor);
        count++;
      } catch (e) {
        debugPrint('[FunctionRouter] Failed to register tool: $e');
      }
    }

    if (count > 0) notifyListeners();
    debugPrint('[FunctionRouter] Loaded $count tools from JSON');
    return count;
  }

  /// 保存当前本地工具配置到 JSON 文件
  Future<bool> saveToJsonFile([String? filePath]) async {
    final path = filePath ?? _localToolsConfigPath;
    if (path == null) return false;

    try {
      final tools = registry.exportLocalToolsJson();
      final data = {
        'version': '1.0',
        'description':
            'Kelivo local tools configuration. '
            'Similar to MCP tool protocol. '
            'See documentation for available executor types.',
        'tools': tools,
      };

      final file = File(path);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
      );
      return true;
    } catch (e) {
      debugPrint('[FunctionRouter] Failed to save config: $e');
      return false;
    }
  }

  /// 初始化配置文件 — 如果不存在则创建默认配置
  Future<void> initConfigFile(String configDir) async {
    final filePath = '$configDir${Platform.pathSeparator}$_kLocalToolsFileName';
    _localToolsConfigPath = filePath;

    final file = File(filePath);
    if (await file.exists()) {
      await loadFromJsonFile(filePath);
    } else {
      // 创建默认配置文件
      await saveToJsonFile(filePath);
      debugPrint('[FunctionRouter] Created default config: $filePath');
    }
  }

  // ============================================================================
  // 动态工具管理
  // ============================================================================

  /// 注册单个本地工具（编程接口）
  void registerLocalTool(ToolDefinition definition) {
    registry.register(definition, _createLocalExecutor(definition));
    notifyListeners();
  }

  /// 注销工具
  void unregisterTool(String name) {
    registry.unregister(name);
    notifyListeners();
  }

  /// 注销所有本地工具并重新加载默认工具
  void resetLocalTools() {
    registry.unregisterBySource(ToolSource.local);
    _registerDefaultLocalTools();
    notifyListeners();
  }

  // ============================================================================
  // 公开 API — 构建工具定义和调用回调
  // ============================================================================

  /// 获取本地工具定义列表（OpenAI function calling 格式）
  ///
  /// 用于注入到 API 请求的 tools 参数中。
  List<Map<String, dynamic>> buildLocalToolDefinitions({
    required String providerKey,
    required ProviderKind providerKind,
  }) {
    final tools = registry.getAvailableTools(
      sources: {ToolSource.local},
    );

    if (tools.isEmpty) return [];

    return tools.map((t) {
      final sanitized = _sanitizeParametersForProvider(
        t.parameters,
        providerKind,
      );
      return {
        'type': 'function',
        'function': {
          'name': t.name,
          'description': t.description,
          'parameters': sanitized,
        },
      };
    }).toList();
  }

  /// 构建工具调用处理器
  ///
  /// 返回一个函数，可以按工具名称路由到对应执行器。
  /// 仅处理本地注册的工具，非本地工具返回 null。
  Future<String?> Function(String, Map<String, dynamic>)
      buildLocalToolCallHandler({
    required String conversationId,
    String? assistantId,
    required ProviderKind providerKind,
  }) {
    final context = ToolContext(
      conversationId: conversationId,
      assistantId: assistantId,
      providerKind: providerKind,
    );

    return (name, args) async {
      if (!registry.hasExecutor(name)) return null;

      final def = registry.getDefinition(name);
      if (def == null) return null;

      // 仅处理本地工具
      if (def.source != ToolSource.local) return null;

      final result = await engine.execute(name, args, context);
      return result.toResponseText();
    };
  }

  /// 直接调用工具（用于测试或手动触发）
  Future<ToolResult> callTool(
    String name,
    Map<String, dynamic> arguments, {
    String conversationId = '',
    ProviderKind providerKind = ProviderKind.openai,
  }) {
    return engine.execute(
      name,
      arguments,
      ToolContext(
        conversationId: conversationId,
        providerKind: providerKind,
      ),
    );
  }

  // ============================================================================
  // 查询
  // ============================================================================

  /// 获取所有已注册工具名称
  List<String> get registeredToolNames => registry.registeredNames;

  /// 获取本地工具名称列表
  List<String> get localToolNames =>
      registry.getNamesBySource(ToolSource.local);

  /// 检查工具是否已注册
  bool isToolRegistered(String name) => registry.hasExecutor(name);

  /// 本地工具是否启用
  bool get hasLocalTools =>
      registry.getNamesBySource(ToolSource.local).isNotEmpty;

  // ============================================================================
  // 内部工具
  // ============================================================================

  /// 简化的 schema 清洗（委托给 ToolHandlerService 复用）
  static Map<String, dynamic> _sanitizeParametersForProvider(
    Map<String, dynamic> schema,
    ProviderKind providerKind,
  ) {
    // 基本清洗: 移除不需要的字段
    final clone = Map<String, dynamic>.from(schema);
    clone.remove(r'$schema');
    return clone;
  }
}
