import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'models/models.dart';

/// 工具执行器类型
typedef ToolExecutor = Future<ToolResult> Function(
  String toolName,
  Map<String, dynamic> arguments,
  ToolContext context,
);

/// 工具注册表
///
/// 管理所有可用工具的元信息和执行器。
/// 支持按来源分组注册/注销，支持从 JSON 批量加载。
class ToolRegistry {
  final Map<String, ToolDefinition> _definitions = {};
  final Map<String, ToolExecutor> _executors = {};

  /// 所有已注册的工具定义 (只读)
  Map<String, ToolDefinition> get definitions =>
      Map.unmodifiable(_definitions);

  // ============================================================================
  // 注册 / 注销
  // ============================================================================

  /// 注册单个工具
  void register(ToolDefinition definition, ToolExecutor executor) {
    _definitions[definition.name] = definition;
    _executors[definition.name] = executor;
  }

  /// 注销单个工具
  void unregister(String name) {
    _definitions.remove(name);
    _executors.remove(name);
  }

  /// 按来源批量注销
  void unregisterBySource(ToolSource source) {
    final names = _definitions.entries
        .where((e) => e.value.source == source)
        .map((e) => e.key)
        .toList();
    for (final n in names) {
      _definitions.remove(n);
      _executors.remove(n);
    }
  }

  /// 从 JSON 列表批量注册工具
  ///
  /// JSON 格式与 MCP 工具协议类似：
  /// ```json
  /// [
  ///   {
  ///     "name": "open_notepad",
  ///     "description": "打开记事本",
  ///     "source": "local",
  ///     "safety": "safe",
  ///     "parameters": { ... },
  ///     "executor": {
  ///       "type": "local_program",
  ///       "mode": "launch",
  ///       "command": "notepad.exe"
  ///     }
  ///   }
  /// ]
  /// ```
  ///
  /// [executorFactory] 根据 executor config 返回执行器实现。
  void registerFromJson(
    List<Map<String, dynamic>> toolConfigs,
    ToolExecutor Function(ToolDefinition definition) executorFactory,
  ) {
    for (final json in toolConfigs) {
      try {
        final def = ToolDefinition.fromJson(json);
        register(def, executorFactory(def));
      } catch (e) {
        debugPrint('[ToolRegistry] Failed to register tool from JSON: $e');
      }
    }
  }

  /// 从 JSON 字符串批量注册
  void registerFromJsonString(
    String jsonStr,
    ToolExecutor Function(ToolDefinition definition) executorFactory,
  ) {
    final list = (jsonDecode(jsonStr) as List)
        .cast<Map<String, dynamic>>();
    registerFromJson(list, executorFactory);
  }

  // ============================================================================
  // 查询
  // ============================================================================

  /// 获取工具定义
  ToolDefinition? getDefinition(String name) => _definitions[name];

  /// 获取工具执行器
  ToolExecutor? getExecutor(String name) => _executors[name];

  /// 检查工具是否存在
  bool hasExecutor(String name) => _executors.containsKey(name);

  /// 获取可用工具定义列表（用于构建 API 请求）
  ///
  /// [enabledNames] — 过滤: 仅返回这些名称的工具 (null = 全部)
  /// [sources] — 过滤: 仅返回这些来源的工具 (null = 全部)
  /// [excludeDangerous] — 排除危险级别的工具
  List<ToolDefinition> getAvailableTools({
    Set<String>? enabledNames,
    Set<ToolSource>? sources,
    bool excludeDangerous = true,
  }) {
    return _definitions.values.where((d) {
      if (excludeDangerous && d.isDangerous) return false;
      if (enabledNames != null && !enabledNames.contains(d.name)) return false;
      if (sources != null && !sources.contains(d.source)) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
  }

  /// 获取所有已注册工具名称
  List<String> get registeredNames => _definitions.keys.toList();

  /// 按来源获取工具名称
  List<String> getNamesBySource(ToolSource source) {
    return _definitions.entries
        .where((e) => e.value.source == source)
        .map((e) => e.key)
        .toList();
  }

  /// 导出所有本地工具为 JSON（用于持久化）
  List<Map<String, dynamic>> exportLocalToolsJson() {
    return _definitions.values
        .where((d) => d.source == ToolSource.local)
        .map((d) => d.toJson())
        .toList();
  }
}
