# Plan Agent 设计文档

## 1. 概述

当前 Kelivo 的函数调用采用「单轮请求-响应 + 多轮工具调用循环」模式，LLM 直接决定调用哪些工具。引入 Plan Agent 后，在工具执行前先让 LLM 生成一个结构化的执行计划（分析意图 → 拆分子步骤 → 逐步执行 → 汇总结果），提高复杂任务的成功率和可观测性。

### 1.1 当前架构

```
用户输入
  ↓
ChatActions.sendMessage()
  ↓
MessageGenerationService.prepareApiMessagesWithInjections()
  ↓
ChatActions._executeGeneration()   ← LLM 直接决定工具调用
  ↓
ChatApiService.sendMessageStream()
  ↓
工具调用循环 (while true)
  ↓
最终响应
```

### 1.2 目标架构

```
用户输入
  ↓
ChatActions.sendMessage()
  ↓
MessageGenerationService.prepareApiMessagesWithInjections()
  ↓
┌──────────────────────────────────┐
│   🆕 Plan Agent 层              │
│                                  │
│  1. 分析用户意图                 │
│  2. 判断是否需要规划             │
│  3. 生成结构化执行计划 (JSON)    │
│  4. [可选] 用户确认/编辑计划     │
│  5. 按步骤编排执行               │
│  6. 汇总结果                     │
└──────────────────────────────────┘
  ↓
ChatActions._executeGeneration()  (可能被多次调用)
```

---

## 2. 数据模型

### 2.1 ExecutionPlan

```dart
/// 执行计划 — 由 Plan Agent 生成
class ExecutionPlan {
  final String id;
  final String goal;            // 用户最终目标的摘要
  final List<PlanStep> steps;   // 有序步骤列表
  final PlanStatus status;      // pending | executing | completed | failed
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? summary;        // 执行完成后的汇总

  // 便捷方法
  PlanStep? get currentStep;              // 当前正在执行的步骤
  List<PlanStep> get completedSteps;      // 已完成的步骤
  double get progress;                     // 完成进度 0.0 ~ 1.0
  bool get canProceed;                     // 是否还有待执行步骤
}
```

### 2.2 PlanStep

```dart
/// 计划中的单个步骤
class PlanStep {
  final String stepId;          // 步骤唯一标识，如 "step_1"
  final int order;              // 执行顺序
  final String description;     // 步骤描述（人类可读）
  final PlanStepAction action;  // 动作类型
  final String? toolName;       // 若 action == toolCall，对应工具名
  final Map<String, dynamic>? toolArgs;  // 工具参数
  final List<String> dependsOn; // 依赖的步骤 ID 列表
  final StepStatus status;      // pending | running | completed | failed | skipped
  final String? result;         // 执行结果
  final String? error;          // 错误信息
  final Duration? executionTime;
}

enum PlanStepAction {
  toolCall,    // 调用工具
  llmQuery,    // 调用 LLM 做子推理
  aggregate,   // 汇总前序步骤结果
  validate,    // 验证/检查
}

enum StepStatus {
  pending,
  running,
  completed,
  failed,
  skipped,
}

enum PlanStatus {
  pending,
  executing,
  completed,
  failed,
  cancelled,
}
```

### 2.3 PlanUIPart（UI 展示用）

```dart
/// 用于在消息气泡中展示计划进度
class PlanUIPart {
  final ExecutionPlan plan;
  final bool isExpanded;  // 用户是否展开查看详情
}
```

---

## 3. 核心服务：PlanAgentService

### 3.1 位置

```
lib/core/services/agent/
  ├── plan_agent_service.dart       // 核心规划服务
  ├── plan_prompt_builder.dart      // 规划 prompt 构建
  └── plan_executor.dart            // 计划执行器
```

### 3.2 职责

```dart
class PlanAgentService {
  final ChatApiService _chatApiService;
  final ToolHandlerService _toolHandlerService;
  final FunctionRouter _functionRouter;

  /// 判断是否需要为当前请求生成计划
  /// 依据：可用工具数量、消息复杂度、用户设置
  Future<bool> shouldPlan({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> toolDefinitions,
    required AssistantSettings settings,
  });

  /// 生成执行计划
  /// 调用 LLM（可配置独立的规划模型），返回结构化 JSON 计划
  Future<ExecutionPlan> generatePlan({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> toolDefinitions,
    required String userGoal,
  });

  /// 逐步执行计划
  /// 返回 Stream 以支持实时 UI 更新
  Stream<PlanExecutionEvent> executePlan({
    required ExecutionPlan plan,
    required GenerationContext context,
  });

  /// 汇总计划执行结果为最终回复
  Future<String> summarizeResults({
    required ExecutionPlan completedPlan,
  });
}
```

### 3.3 规划 Prompt 设计

```dart
class PlanPromptBuilder {
  /// 构建规划 system prompt
  static String buildPlanningSystemPrompt({
    required List<Map<String, dynamic>> toolDefinitions,
  }) {
    return '''
你是一个任务规划助手。你的职责是分析用户的请求，并生成一个结构化的执行计划。

## 可用工具
${_formatToolList(toolDefinitions)}

## 输出格式
请以 JSON 格式输出执行计划：
```json
{
  "goal": "用户目标的简洁描述",
  "needs_planning": true,
  "reasoning": "为什么需要/不需要规划",
  "steps": [
    {
      "step_id": "step_1",
      "description": "步骤描述",
      "action": "tool_call | llm_query | aggregate | validate",
      "tool_name": "工具名称（仅 tool_call 时）",
      "tool_args": {},
      "depends_on": []
    }
  ]
}
```

## 规则
1. 只在任务确实需要多步骤协作时才设置 needs_planning = true
2. 简单的单工具调用不需要规划
3. 步骤之间通过 depends_on 声明依赖关系
4. 优先并行无依赖的步骤
5. 最后一步通常是 aggregate 汇总结果
''';
  }
}
```

---

## 4. 集成方案

### 4.1 在 ChatActions 中插入规划层

```dart
// ChatActions.sendMessage() 中，在 _executeGeneration() 前插入：

Future<void> sendMessage(...) async {
  // ... 现有代码：创建消息、准备 API 消息 ...

  final generationContext = ...;

  // 🆕 Plan Agent 拦截
  if (_planAgentService.shouldPlan(
    messages: generationContext.messages,
    toolDefinitions: generationContext.toolDefinitions,
    settings: currentAssistant.settings,
  )) {
    await _executeWithPlan(generationContext);
  } else {
    await _executeGeneration(generationContext);  // 现有逻辑
  }
}

Future<void> _executeWithPlan(GenerationContext context) async {
  // 1. 生成计划
  final plan = await _planAgentService.generatePlan(
    messages: context.messages,
    toolDefinitions: context.toolDefinitions,
    userGoal: _extractUserGoal(context),
  );

  // 2. 通知 UI 显示计划
  _streamController.addPlanUIPart(plan);

  // 3. 逐步执行
  await for (final event in _planAgentService.executePlan(
    plan: plan,
    context: context,
  )) {
    _handlePlanEvent(event);
  }

  // 4. 汇总结果
  final summary = await _planAgentService.summarizeResults(
    completedPlan: plan,
  );

  // 5. 更新助手消息
  _updateAssistantMessage(summary);
}
```

### 4.2 在 ToolHandlerService 中注册 plan 工具（LLM 自主触发模式）

```dart
// ToolHandlerService.buildToolDefinitions() 中添加：

Map<String, dynamic> _buildPlanToolDefinition() {
  return {
    'type': 'function',
    'function': {
      'name': 'create_execution_plan',
      'description': '当任务需要多个步骤协作完成时，创建一个结构化的执行计划。'
                     '适用于复杂查询、多工具协作、需要中间结果的场景。',
      'parameters': {
        'type': 'object',
        'properties': {
          'goal': {
            'type': 'string',
            'description': '任务目标描述',
          },
          'steps': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'description': {'type': 'string'},
                'tool_name': {'type': 'string'},
                'tool_args': {'type': 'object'},
                'depends_on': {
                  'type': 'array',
                  'items': {'type': 'string'},
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
```

---

## 5. 规划触发策略

### 5.1 三种模式

| 模式 | 触发条件 | 适用场景 |
|------|----------|----------|
| **Always** | 每次请求都先规划 | 全 Agent 模式 |
| **Auto** | 可用工具数 ≥ N 或用户意图复杂时 | 推荐默认 |
| **Manual** | 用户手动开关 | 精确控制 |

### 5.2 Auto 模式判定逻辑

```dart
Future<bool> shouldPlan(...) async {
  // 1. 检查用户设置
  if (settings.planMode == PlanMode.always) return true;
  if (settings.planMode == PlanMode.never) return false;

  // 2. Auto 模式下的启发式判断
  final toolCount = toolDefinitions.length;
  final lastUserMessage = _extractLastUserMessage(messages);
  
  // 2a. 工具数量阈值
  if (toolCount < 3) return false;

  // 2b. 消息长度/复杂度
  if (lastUserMessage.length < 50) return false;

  // 2c. 关键词检测（多步骤暗示）
  final planningIndicators = [
    '然后', '接着', '首先', '最后',
    '分别', '对比', '汇总', '综合',
    'then', 'first', 'finally', 'compare',
    'step by step', 'one by one',
  ];
  final hasIndicators = planningIndicators.any(
    (kw) => lastUserMessage.toLowerCase().contains(kw),
  );

  // 2d. 快速 LLM 判断（可选，低 token 消耗）
  if (toolCount >= 5 || hasIndicators) {
    return await _quickPlanCheck(lastUserMessage, toolDefinitions);
  }

  return false;
}
```

---

## 6. UI 展示

### 6.1 计划卡片组件

在消息气泡中展示计划进度，复用现有 `ToolUIPart` 的展示模式：

```
┌─────────────────────────────────────┐
│ 📋 执行计划                    ▼ 展开 │
│                                     │
│ 目标: 对比北京和上海今天的天气       │
│                                     │
│ ✅ Step 1: 搜索北京天气    (0.3s)   │
│ ✅ Step 2: 搜索上海天气    (0.5s)   │
│ 🔄 Step 3: 对比分析        进行中   │
│ ⏳ Step 4: 生成汇总报告    等待中   │
│                                     │
│ 进度: ████████░░ 75%                │
└─────────────────────────────────────┘
```

### 6.2 状态图标映射

```
pending   → ⏳
running   → 🔄
completed → ✅
failed    → ❌
skipped   → ⏭️
```

---

## 7. 文件结构

```
lib/
  core/
    models/
      execution_plan.dart         // ExecutionPlan, PlanStep 数据模型
      plan_enums.dart             // PlanStatus, StepStatus, PlanStepAction 枚举
    services/
      agent/
        plan_agent_service.dart   // 核心规划服务
        plan_prompt_builder.dart  // 规划 prompt 构建
        plan_executor.dart        // 计划执行器
  features/
    home/
      controllers/
        stream_controller.dart    // 扩展：支持 PlanUIPart
      services/
        chat_actions.dart         // 扩展：插入规划拦截层
        tool_handler_service.dart // 扩展：注册 plan 工具
      widgets/
        plan_card_widget.dart     // 计划卡片 UI 组件
```

---

## 8. 关键复用点

| 现有组件 | 复用方式 |
|---------|---------|
| `ChatApiService.sendMessageStream()` | 调用 LLM 做规划推理 |
| `ToolHandlerService.buildToolCallHandler()` | 执行计划中的工具调用步骤 |
| `FunctionRouter.callTool()` | 程序化调用本地/MCP 工具 |
| `StreamController` + `ToolUIPart` | 展示计划步骤执行状态 |
| `ChatService.toolEventsBox` | 持久化计划执行记录 |
| `GenerationContext` | 传递上下文给子步骤 |

---

## 9. 注意事项

1. **规划 LLM 调用成本** — 规划本身需要额外一次 LLM 调用，建议支持配置独立的规划模型（更轻量/更便宜），与执行模型分离。
2. **计划可编辑性** — 可选地允许用户在计划生成后、执行前进行手动编辑/确认/跳过某些步骤，增加可控性。
3. **错误恢复** — 当某个步骤失败时，Plan Agent 应能决定是重试、跳过还是中止整个计划。
4. **并行执行** — 无依赖关系的步骤应尽可能并行执行以提升效率。
5. **Token 预算** — 规划步骤的 LLM 调用应设置较小的 `max_tokens` 以控制成本。
6. **向后兼容** — Plan Agent 默认关闭或设为 Auto 模式，不影响现有用户体验。
