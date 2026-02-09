import 'dart:convert';

/// 工具来源类型
enum ToolSource {
  /// 内置工具 (search, memory 等)
  builtin,

  /// MCP 服务器工具
  mcp,

  /// 本地工具 (通过 JSON 注册的本地程序等)
  local,

  /// 用户自定义工具
  custom,
}

/// 工具安全级别
enum ToolSafetyLevel {
  /// 安全 — 直接执行，无需确认
  safe,

  /// 需确认 — 执行前弹窗确认
  confirm,

  /// 危险 — 禁止执行
  dangerous,
}

/// 本地程序执行模式
enum LocalProgramMode {
  /// 启动并立即返回（如打开记事本窗口）
  launch,

  /// 运行并等待输出（如执行 `dir` 命令）
  run,
}

/// 工具定义
///
/// 统一描述所有类型工具（内置、MCP、本地、自定义）的元信息。
/// 支持从 JSON 反序列化，与 MCP 协议风格一致。
///
/// JSON 注册示例:
/// ```json
/// {
///   "name": "open_notepad",
///   "description": "打开 Windows 记事本",
///   "source": "local",
///   "priority": 15,
///   "safety": "safe",
///   "parameters": {
///     "type": "object",
///     "properties": {
///       "file": {
///         "type": "string",
///         "description": "可选：要打开的文件路径"
///       }
///     }
///   },
///   "executor": {
///     "type": "local_program",
///     "mode": "launch",
///     "command": "notepad.exe",
///     "defaultArgs": []
///   }
/// }
/// ```
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON Schema
  final ToolSource source;
  final int priority; // 数字越小优先级越高
  final Set<String>? requiredCapabilities; // 所需能力
  final ToolSafetyLevel safety;
  final Map<String, dynamic>? executorConfig; // 执行器配置

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    this.source = ToolSource.custom,
    this.priority = 100,
    this.requiredCapabilities,
    this.safety = ToolSafetyLevel.safe,
    this.executorConfig,
  });

  bool get requiresConfirmation => safety == ToolSafetyLevel.confirm;
  bool get isDangerous => safety == ToolSafetyLevel.dangerous;

  /// 从 JSON Map 反序列化
  factory ToolDefinition.fromJson(Map<String, dynamic> json) {
    return ToolDefinition(
      name: json['name'] as String,
      description: (json['description'] ?? '') as String,
      parameters: (json['parameters'] as Map<String, dynamic>?) ??
          const {'type': 'object', 'properties': {}},
      source: _parseSource(json['source']),
      priority: (json['priority'] as int?) ?? 100,
      requiredCapabilities: json['requiredCapabilities'] != null
          ? Set<String>.from(json['requiredCapabilities'] as List)
          : null,
      safety: _parseSafety(json['safety']),
      executorConfig: json['executor'] as Map<String, dynamic>?,
    );
  }

  /// 序列化为 JSON Map
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'parameters': parameters,
      'source': source.name,
      'priority': priority,
      if (requiredCapabilities != null)
        'requiredCapabilities': requiredCapabilities!.toList(),
      'safety': safety.name,
      if (executorConfig != null) 'executor': executorConfig,
    };
  }

  /// 从 JSON 字符串反序列化
  factory ToolDefinition.fromJsonString(String jsonStr) {
    return ToolDefinition.fromJson(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
  }

  /// 序列化为 JSON 字符串
  String toJsonString() => jsonEncode(toJson());

  /// 转换为 OpenAI function calling 格式
  Map<String, dynamic> toOpenAIFormat() {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };
  }

  static ToolSource _parseSource(dynamic value) {
    if (value == null) return ToolSource.custom;
    final str = value.toString().toLowerCase();
    return ToolSource.values.firstWhere(
      (e) => e.name == str,
      orElse: () => ToolSource.custom,
    );
  }

  static ToolSafetyLevel _parseSafety(dynamic value) {
    if (value == null) return ToolSafetyLevel.safe;
    final str = value.toString().toLowerCase();
    return ToolSafetyLevel.values.firstWhere(
      (e) => e.name == str,
      orElse: () => ToolSafetyLevel.safe,
    );
  }

  @override
  String toString() => 'ToolDefinition($name, source=$source, priority=$priority)';
}
