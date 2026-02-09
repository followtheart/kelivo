# Kelivo Function Calling & Function Router 设计文档

## 1. 概述

本文档描述 Kelivo 聊天客户端的 **Function Calling** 与 **Function Router** 架构设计，旨在统一管理内置工具、MCP 工具和自定义函数的调用路由。

### 1.1 设计目标

- **统一入口**：所有工具调用通过 Function Router 统一路由
- **可扩展性**：支持动态注册新工具，无需修改核心代码
- **多提供商兼容**：自动适配 OpenAI / Claude / Gemini 的 tools 格式差异
- **优先级控制**：支持工具调用的优先级和冲突解决
- **可观测性**：完整的工具调用日志和监控

### 1.2 现有基础设施

| 组件 | 位置 | 状态 |
|------|------|------|
| `ToolHandlerService` | `lib/features/home/services/tool_handler_service.dart` | ✅ 已有 |
| `McpToolService` | `lib/core/services/mcp/mcp_tool_service.dart` | ✅ 已有 |
| `SearchToolService` | `lib/core/services/search/search_tool_service.dart` | ✅ 已有 |
| `BuiltInToolNames` | `lib/core/models/` | ✅ 已有 |
| **FunctionRouter** | `lib/core/services/function_calling/` | 🆕 待实现 |

---

## 2. 架构设计

### 2.1 整体架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Chat Stream Controller                       │
│                    (lib/features/home/controllers/)                  │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         Function Router                              │
│              (lib/core/services/function_calling/)                   │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  ToolRegistry        │  RouteResolver      │  ExecutionEngine │  │
│  │  - Built-in tools    │  - Priority rules   │  - Sync/Async    │  │
│  │  - MCP tools         │  - Conflict policy  │  - Timeout       │  │
│  │  - Custom tools      │  - Fallback chain   │  - Retry         │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
            ┌─────────────────────┼─────────────────────┐
            ▼                     ▼                     ▼
    ┌───────────────┐     ┌───────────────┐     ┌───────────────┐
    │  Built-in     │     │  MCP Tools    │     │  Custom       │
    │  Handlers     │     │  (External)   │     │  Handlers     │
    ├───────────────┤     ├───────────────┤     ├───────────────┤
    │ • search      │     │ • filesystem  │     │ • user-defined│
    │ • memory_*    │     │ • database    │     │ • plugins     │
    │ • url_context │     │ • browser     │     │               │
    │ • code_exec   │     │ • ...         │     │               │
    └───────────────┘     └───────────────┘     └───────────────┘
```

### 2.2 核心组件

#### 2.2.1 ToolRegistry（工具注册表）

负责管理所有可用工具的元信息和执行器。

```dart
/// lib/core/services/function_calling/tool_registry.dart

/// 工具来源类型
enum ToolSource {
  builtin,    // 内置工具
  mcp,        // MCP 服务器工具
  custom,     // 自定义工具
}

/// 工具定义
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;  // JSON Schema
  final ToolSource source;
  final int priority;                      // 优先级 (数字越小优先级越高)
  final Set<String>? requiredCapabilities; // 所需能力 (如 'network', 'filesystem')
  final bool requiresConfirmation;         // 是否需要用户确认
  
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    this.source = ToolSource.custom,
    this.priority = 100,
    this.requiredCapabilities,
    this.requiresConfirmation = false,
  });
}

/// 工具执行器类型
typedef ToolExecutor = Future<ToolResult> Function(
  String toolName,
  Map<String, dynamic> arguments,
  ToolContext context,
);

/// 工具注册表
class ToolRegistry {
  final Map<String, ToolDefinition> _definitions = {};
  final Map<String, ToolExecutor> _executors = {};
  
  /// 注册工具
  void register(ToolDefinition definition, ToolExecutor executor);
  
  /// 批量注册 MCP 工具
  void registerMcpTools(List<McpToolConfig> tools, McpToolService service);
  
  /// 注销工具
  void unregister(String name);
  
  /// 按来源注销工具
  void unregisterBySource(ToolSource source);
  
  /// 获取所有工具定义 (用于 API 请求)
  List<ToolDefinition> getAvailableTools({
    Set<String>? enabledNames,
    Set<ToolSource>? sources,
  });
  
  /// 检查工具是否存在
  bool hasExecutor(String name);
}
```

#### 2.2.2 RouteResolver（路由解析器）

决定工具调用如何路由到具体执行器。

```dart
/// lib/core/services/function_calling/route_resolver.dart

/// 路由策略
enum RouteStrategy {
  firstMatch,     // 第一个匹配的执行器
  priorityBased,  // 按优先级选择
  roundRobin,     // 轮询 (用于负载均衡)
  fallbackChain,  // 链式回退
}

/// 路由规则
class RouteRule {
  final String? toolNamePattern;  // 工具名匹配模式 (支持通配符)
  final ToolSource? preferredSource;
  final RouteStrategy strategy;
  final List<String>? fallbackChain;  // 回退链
  
  const RouteRule({
    this.toolNamePattern,
    this.preferredSource,
    this.strategy = RouteStrategy.priorityBased,
    this.fallbackChain,
  });
}

/// 路由解析器
class RouteResolver {
  final List<RouteRule> _rules = [];
  
  /// 添加路由规则
  void addRule(RouteRule rule);
  
  /// 移除路由规则
  void removeRule(String? toolNamePattern);
  
  /// 解析工具调用路由
  /// 返回: 执行器名称列表 (按优先级排序)
  List<String> resolve(String toolName, ToolContext context);
}
```

#### 2.2.3 ExecutionEngine（执行引擎）

负责实际执行工具调用，处理超时、重试和结果转换。

```dart
/// lib/core/services/function_calling/execution_engine.dart

/// 工具调用上下文
class ToolContext {
  final String conversationId;
  final String? assistantId;
  final ProviderKind providerKind;
  final Map<String, dynamic> metadata;
  
  const ToolContext({
    required this.conversationId,
    this.assistantId,
    required this.providerKind,
    this.metadata = const {},
  });
}

/// 工具执行结果
class ToolResult {
  final bool success;
  final String content;           // 文本结果
  final List<String>? imageUrls;  // 图片结果
  final Map<String, dynamic>? structuredData;  // 结构化数据
  final String? errorMessage;
  final Duration executionTime;
  
  const ToolResult({
    required this.success,
    required this.content,
    this.imageUrls,
    this.structuredData,
    this.errorMessage,
    required this.executionTime,
  });
  
  /// 工厂方法: 成功结果
  factory ToolResult.success(String content, {Duration? executionTime}) {
    return ToolResult(
      success: true,
      content: content,
      executionTime: executionTime ?? Duration.zero,
    );
  }
  
  /// 工厂方法: 失败结果
  factory ToolResult.failure(String error, {Duration? executionTime}) {
    return ToolResult(
      success: false,
      content: '',
      errorMessage: error,
      executionTime: executionTime ?? Duration.zero,
    );
  }
  
  /// 转换为 API 响应格式
  String toResponseText() {
    if (!success) {
      return 'Error: ${errorMessage ?? "Unknown error"}';
    }
    return content;
  }
}

/// 执行配置
class ExecutionConfig {
  final Duration timeout;
  final int maxRetries;
  final Duration retryDelay;
  final bool parallelExecution;  // 是否并行执行多个工具
  
  const ExecutionConfig({
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    this.retryDelay = const Duration(seconds: 1),
    this.parallelExecution = false,
  });
}

/// 执行中间件
typedef ExecutionMiddleware = Future<void> Function(
  String toolName,
  Map<String, dynamic> arguments,
  ToolContext context,
);

/// 执行引擎
class ExecutionEngine {
  final ToolRegistry _registry;
  final RouteResolver _resolver;
  final ExecutionConfig config;
  
  final List<ExecutionMiddleware> _beforeMiddlewares = [];
  final List<ExecutionMiddleware> _afterMiddlewares = [];
  
  ExecutionEngine({
    required ToolRegistry registry,
    required RouteResolver resolver,
    this.config = const ExecutionConfig(),
  }) : _registry = registry, _resolver = resolver;
  
  /// 添加执行前中间件
  void addBeforeMiddleware(ExecutionMiddleware middleware);
  
  /// 添加执行后中间件
  void addAfterMiddleware(ExecutionMiddleware middleware);
  
  /// 执行单个工具调用
  Future<ToolResult> execute(
    String toolName,
    Map<String, dynamic> arguments,
    ToolContext context,
  );
  
  /// 批量执行工具调用 (支持并行)
  Future<List<ToolResult>> executeBatch(
    List<ToolCall> calls,
    ToolContext context,
  );
}
```

#### 2.2.4 FunctionRouter（函数路由器 - 门面类）

整合以上组件，提供简洁的对外接口。

```dart
/// lib/core/services/function_calling/function_router.dart

import 'package:flutter/foundation.dart';

/// 函数路由器 - 统一入口
class FunctionRouter extends ChangeNotifier {
  late final ToolRegistry registry;
  late final RouteResolver resolver;
  late final ExecutionEngine engine;
  
  FunctionRouter() {
    registry = ToolRegistry();
    resolver = RouteResolver();
    engine = ExecutionEngine(
      registry: registry,
      resolver: resolver,
    );
    _registerBuiltinTools();
    _setupDefaultRouteRules();
  }
  
  // ============================================================
  // 初始化
  // ============================================================
  
  /// 注册内置工具
  void _registerBuiltinTools() {
    // Search tool
    registry.register(
      ToolDefinition(
        name: 'search',
        description: 'Search the web for current information',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query'
            }
          },
          'required': ['query']
        },
        source: ToolSource.builtin,
        priority: 10,
      ),
      _executeSearchTool,
    );
    
    // Memory tools
    registry.register(
      ToolDefinition(
        name: 'create_memory',
        description: 'Create a memory record for the user',
        parameters: {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': 'The content of the memory record'
            }
          },
          'required': ['content']
        },
        source: ToolSource.builtin,
        priority: 20,
      ),
      _executeMemoryTool,
    );
    
    registry.register(
      ToolDefinition(
        name: 'edit_memory',
        description: 'Update an existing memory record',
        parameters: {
          'type': 'object',
          'properties': {
            'id': {'type': 'integer', 'description': 'The id of the memory record'},
            'content': {'type': 'string', 'description': 'The new content'}
          },
          'required': ['id', 'content']
        },
        source: ToolSource.builtin,
        priority: 20,
      ),
      _executeMemoryTool,
    );
    
    registry.register(
      ToolDefinition(
        name: 'delete_memory',
        description: 'Delete a memory record',
        parameters: {
          'type': 'object',
          'properties': {
            'id': {'type': 'integer', 'description': 'The id of the memory record'}
          },
          'required': ['id']
        },
        source: ToolSource.builtin,
        priority: 20,
      ),
      _executeMemoryTool,
    );
  }
  
  /// 设置默认路由规则
  void _setupDefaultRouteRules() {
    // 内置工具优先
    resolver.addRule(RouteRule(
      toolNamePattern: 'search',
      preferredSource: ToolSource.builtin,
      strategy: RouteStrategy.firstMatch,
    ));
    
    resolver.addRule(RouteRule(
      toolNamePattern: '*_memory',
      preferredSource: ToolSource.builtin,
      strategy: RouteStrategy.firstMatch,
    ));
    
    // MCP 工具带回退
    resolver.addRule(RouteRule(
      toolNamePattern: '*',
      preferredSource: ToolSource.mcp,
      strategy: RouteStrategy.fallbackChain,
      fallbackChain: ['mcp', 'builtin', 'custom'],
    ));
  }
  
  // ============================================================
  // 工具执行器实现
  // ============================================================
  
  Future<ToolResult> _executeSearchTool(
    String name,
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final query = (args['query'] ?? '').toString();
      // 调用 SearchToolService
      final result = await SearchToolService.executeSearch(query, _settings);
      stopwatch.stop();
      return ToolResult.success(result, executionTime: stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      return ToolResult.failure(e.toString(), executionTime: stopwatch.elapsed);
    }
  }
  
  Future<ToolResult> _executeMemoryTool(
    String name,
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      // 委托给 ToolHandlerService._handleMemoryToolCall
      final result = await _toolHandler._handleMemoryToolCall(name, args, _assistant);
      stopwatch.stop();
      return ToolResult.success(result ?? '', executionTime: stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      return ToolResult.failure(e.toString(), executionTime: stopwatch.elapsed);
    }
  }
  
  Future<ToolResult> _executeMcpTool(
    String name,
    Map<String, dynamic> args,
    ToolContext ctx,
    McpToolService toolService,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await toolService.callToolTextForConversation(
        _mcpProvider,
        _chatService,
        conversationId: ctx.conversationId,
        toolName: name,
        arguments: args,
      );
      stopwatch.stop();
      return ToolResult.success(result, executionTime: stopwatch.elapsed);
    } catch (e) {
      stopwatch.stop();
      return ToolResult.failure(e.toString(), executionTime: stopwatch.elapsed);
    }
  }
  
  // ============================================================
  // MCP 工具同步
  // ============================================================
  
  /// 同步 MCP 工具 (当 MCP 服务器连接/断开时调用)
  void syncMcpTools(McpProvider mcpProvider, McpToolService toolService) {
    // 清除旧的 MCP 工具
    registry.unregisterBySource(ToolSource.mcp);
    
    // 注册新的 MCP 工具
    for (final server in mcpProvider.connectedServers) {
      for (final tool in server.tools.where((t) => t.enabled)) {
        registry.register(
          ToolDefinition(
            name: tool.name,
            description: tool.description ?? '',
            parameters: tool.schema ?? {'type': 'object', 'properties': {}},
            source: ToolSource.mcp,
            priority: 50,
          ),
          (name, args, ctx) => _executeMcpTool(name, args, ctx, toolService),
        );
      }
    }
    notifyListeners();
  }
  
  // ============================================================
  // 公开 API
  // ============================================================
  
  /// 获取工具定义列表 (用于 API 请求)
  List<Map<String, dynamic>> buildToolsPayload({
    required ProviderKind providerKind,
    required Set<String> enabledTools,
    required bool supportsTools,
  }) {
    if (!supportsTools) return [];
    
    final tools = registry.getAvailableTools(enabledNames: enabledTools);
    return tools.map((t) {
      final sanitized = ToolHandlerService.sanitizeToolParametersForProvider(
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
  
  /// 构建工具调用处理器 (传递给 ChatApiService)
  Future<String> Function(String, Map<String, dynamic>) buildToolCallHandler({
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
      final result = await engine.execute(name, args, context);
      return result.toResponseText();
    };
  }
  
  /// 直接调用工具 (用于测试或手动触发)
  Future<ToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) => engine.execute(name, arguments, context);
  
  /// 获取所有已注册工具名称
  List<String> get registeredToolNames => registry._definitions.keys.toList();
  
  /// 检查工具是否已注册
  bool isToolRegistered(String name) => registry.hasExecutor(name);
}
```

---

## 3. 路由规则配置

### 3.1 默认路由规则

```dart
/// 默认路由配置
final defaultRouteRules = [
  // 内置工具优先
  RouteRule(
    toolNamePattern: 'search',
    preferredSource: ToolSource.builtin,
    strategy: RouteStrategy.firstMatch,
  ),
  RouteRule(
    toolNamePattern: '*_memory',
    preferredSource: ToolSource.builtin,
    strategy: RouteStrategy.firstMatch,
  ),
  
  // MCP 工具带回退
  RouteRule(
    toolNamePattern: '*',
    preferredSource: ToolSource.mcp,
    strategy: RouteStrategy.fallbackChain,
    fallbackChain: ['mcp', 'builtin', 'custom'],
  ),
];
```

### 3.2 工具名称冲突解决

当多个来源提供同名工具时：

| 场景 | 解决策略 |
|------|----------|
| 内置 vs MCP | 优先使用内置 (priority 更低) |
| MCP vs MCP (多服务器) | 按服务器配置顺序 |
| 自定义 vs 其他 | 自定义优先级最低，作为兜底 |

### 3.3 优先级数值约定

| 来源 | 默认优先级 | 说明 |
|------|-----------|------|
| builtin (核心) | 10 | search, url_context |
| builtin (扩展) | 20 | memory_*, code_exec |
| mcp | 50 | MCP 服务器工具 |
| custom | 100 | 用户自定义工具 |

---

## 4. 集成方案

### 4.1 Provider 注册

```dart
/// main.dart
MultiProvider(
  providers: [
    // ... existing providers
    ChangeNotifierProvider(create: (_) => FunctionRouter()),
  ],
)
```

### 4.2 与 ChatStreamController 集成

```dart
/// lib/features/home/controllers/chat_stream_controller.dart

Future<void> sendMessage(...) async {
  final router = context.read<FunctionRouter>();
  final settings = context.read<SettingsProvider>();
  
  // 获取 provider 类型
  final providerCfg = settings.getProviderConfig(providerKey);
  final providerKind = ProviderConfig.classify(
    providerCfg.id,
    explicitType: providerCfg.providerType,
  );
  
  // 构建工具配置
  final tools = router.buildToolsPayload(
    providerKind: providerKind,
    enabledTools: _getEnabledToolsForConversation(conversationId),
    supportsTools: _isToolModel(providerKey, modelId),
  );
  
  // 构建回调
  final onToolCall = router.buildToolCallHandler(
    conversationId: conversationId,
    assistantId: assistant?.id,
    providerKind: providerKind,
  );
  
  // 发送请求
  yield* ChatApiService.sendMessageStream(
    config: providerCfg,
    modelId: modelId,
    messages: messages,
    tools: tools.isNotEmpty ? tools : null,
    onToolCall: tools.isNotEmpty ? onToolCall : null,
    // ... other params
  );
}
```

### 4.3 MCP 工具同步

```dart
/// lib/core/providers/mcp_provider.dart

class McpProvider extends ChangeNotifier {
  FunctionRouter? _router;
  McpToolService? _toolService;
  
  /// 设置 FunctionRouter 引用
  void setFunctionRouter(FunctionRouter router, McpToolService toolService) {
    _router = router;
    _toolService = toolService;
  }
  
  void _onServerConnected(String serverId) async {
    // ... existing connection logic
    
    // 同步到 FunctionRouter
    _router?.syncMcpTools(this, _toolService!);
  }
  
  void _onServerDisconnected(String serverId) {
    // ... existing disconnection logic
    
    // 同步到 FunctionRouter
    _router?.syncMcpTools(this, _toolService!);
  }
}
```

### 4.4 初始化顺序

```dart
/// main.dart 或 app initialization

void initializeServices(BuildContext context) {
  final router = context.read<FunctionRouter>();
  final mcpProvider = context.read<McpProvider>();
  final mcpToolService = context.read<McpToolService>();
  
  // 建立关联
  mcpProvider.setFunctionRouter(router, mcpToolService);
  
  // 初始同步已连接的 MCP 服务器
  router.syncMcpTools(mcpProvider, mcpToolService);
}
```

---

## 5. 文件结构

```
lib/core/services/function_calling/
├── function_router.dart          # 门面类，统一入口
├── tool_registry.dart            # 工具注册表
├── route_resolver.dart           # 路由解析器
├── execution_engine.dart         # 执行引擎
├── models/
│   ├── tool_definition.dart      # 工具定义模型
│   ├── tool_result.dart          # 执行结果模型
│   ├── tool_context.dart         # 调用上下文
│   └── route_rule.dart           # 路由规则
├── handlers/
│   ├── builtin_handlers.dart     # 内置工具处理器
│   └── mcp_handler.dart          # MCP 工具处理器
└── index.dart                    # 导出文件
```

---

## 6. 实现步骤

### Phase 1: 核心框架 (Week 1)

- [ ] 创建 `lib/core/services/function_calling/` 目录结构
- [ ] 实现 `ToolDefinition`, `ToolResult`, `ToolContext` 模型
- [ ] 实现 `ToolRegistry` 基础功能 (register, unregister, getAvailableTools)
- [ ] 实现 `ExecutionEngine` 基础执行逻辑 (execute, timeout handling)
- [ ] 单元测试: ToolRegistry, ExecutionEngine

### Phase 2: 路由能力 (Week 2)

- [ ] 实现 `RouteRule` 模型和通配符匹配
- [ ] 实现 `RouteResolver` 完整功能
- [ ] 实现 `FunctionRouter` 门面类
- [ ] 迁移现有 `ToolHandlerService.buildToolCallHandler` 逻辑
- [ ] 单元测试: RouteResolver, FunctionRouter

### Phase 3: 集成 (Week 3)

- [ ] 注册 `FunctionRouter` Provider 到 `main.dart`
- [ ] 修改 `ChatStreamController` 使用 `FunctionRouter`
- [ ] 实现 MCP 工具自动同步 (`McpProvider` 回调)
- [ ] 移除 `ToolHandlerService` 中的重复逻辑
- [ ] 集成测试: 端到端工具调用流程

### Phase 4: 增强 (Week 4)

- [ ] 添加工具调用日志服务 (`ToolCallLogger`)
- [ ] 实现用户确认机制 (高风险工具弹窗)
- [ ] 添加工具调用结果缓存 (可选)
- [ ] UI: 工具配置面板 (启用/禁用工具)
- [ ] 文档: API 文档和使用指南

---

## 7. 扩展点

### 7.1 自定义工具注册 API

```dart
// 用户可通过配置文件或代码注册自定义工具
final router = context.read<FunctionRouter>();

router.registry.register(
  ToolDefinition(
    name: 'my_custom_tool',
    description: 'A custom tool that does something useful',
    parameters: {
      'type': 'object',
      'properties': {
        'input': {'type': 'string', 'description': 'The input value'}
      },
      'required': ['input']
    },
    source: ToolSource.custom,
    priority: 100,
  ),
  (name, args, ctx) async {
    // 自定义执行逻辑
    final input = args['input'] as String;
    final result = await myCustomFunction(input);
    return ToolResult.success(result);
  },
);
```

### 7.2 中间件支持

```dart
// 支持执行前/后钩子
router.engine.addBeforeMiddleware((name, args, ctx) async {
  // 日志记录
  debugPrint('[Tool] Calling $name with args: $args');
});

router.engine.addAfterMiddleware((name, args, ctx) async {
  // 统计、缓存
  Analytics.trackToolCall(name);
});
```

### 7.3 工具调用确认

```dart
// 高风险工具需要用户确认
registry.register(
  ToolDefinition(
    name: 'delete_file',
    description: 'Delete a file from the filesystem',
    parameters: {...},
    source: ToolSource.mcp,
    requiresConfirmation: true,  // 需要确认
  ),
  _executeDeleteFile,
);

// ExecutionEngine 中检查
if (definition.requiresConfirmation) {
  final confirmed = await _showConfirmationDialog(name, args);
  if (!confirmed) {
    return ToolResult.failure('User cancelled the operation');
  }
}
```

### 7.4 Provider 格式适配器

```dart
/// 自动适配不同 LLM 提供商的 tools 格式
class ToolFormatAdapter {
  /// OpenAI 格式
  static Map<String, dynamic> toOpenAI(ToolDefinition def) {
    return {
      'type': 'function',
      'function': {
        'name': def.name,
        'description': def.description,
        'parameters': def.parameters,
      },
    };
  }
  
  /// Claude 格式
  static Map<String, dynamic> toClaude(ToolDefinition def) {
    return {
      'name': def.name,
      'description': def.description,
      'input_schema': def.parameters,
    };
  }
  
  /// Gemini 格式
  static Map<String, dynamic> toGemini(ToolDefinition def) {
    return {
      'name': def.name,
      'description': def.description,
      'parameters': _sanitizeForGemini(def.parameters),
    };
  }
}
```

---

## 8. 监控与日志

### 8.1 工具调用日志结构

```dart
class ToolCallLog {
  final String id;
  final String toolName;
  final Map<String, dynamic> arguments;
  final ToolSource source;
  final String conversationId;
  final DateTime startTime;
  final DateTime? endTime;
  final Duration? executionTime;
  final bool success;
  final String? errorMessage;
  final String? resultPreview;  // 结果前 200 字符
}
```

### 8.2 统计指标

- 工具调用次数 (按工具名、按来源)
- 平均执行时间
- 成功率
- 错误分布

---

## 9. 参考

- [OpenAI Function Calling](https://platform.openai.com/docs/guides/function-calling)
- [Anthropic Tool Use](https://docs.anthropic.com/en/docs/tool-use)
- [Google Gemini Function Calling](https://ai.google.dev/gemini-api/docs/function-calling)
- [MCP Protocol Specification](https://modelcontextprotocol.io/)

---

## 10. 变更记录

| 日期 | 版本 | 描述 |
|------|------|------|
| 2026-01-30 | 1.0 | 初始设计文档 |
