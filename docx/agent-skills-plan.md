# Agent Skills 集成规划

## 1. Agent Skills 规范摘要

**Agent Skills** 是一种轻量、开放的格式，用于通过专业知识和工作流扩展 AI Agent 的能力。

### 1.1 核心概念

| 概念 | 说明 |
|------|------|
| **Skill** | 一个包含 `SKILL.md` 的文件夹，描述一项可被 Agent 调用的专业能力 |
| **SKILL.md** | 必需文件，YAML frontmatter（元数据）+ Markdown（指令正文） |
| **渐进式加载** | 启动时仅加载 name+description (~100 tokens)；激活时加载完整指令 (<5000 tokens)；按需加载 scripts/references/assets |

### 1.2 目录结构

```
skill-name/
├── SKILL.md          # 必需：元数据 + 指令
├── scripts/          # 可选：可执行代码
├── references/       # 可选：参考文档
└── assets/           # 可选：模板、资源
```

### 1.3 SKILL.md 格式

```yaml
---
name: skill-name            # 必需，1-64字符，小写字母+数字+连字符
description: 描述...         # 必需，1-1024字符，描述功能和使用时机
license: Apache-2.0          # 可选
compatibility: ...           # 可选，环境要求
metadata:                    # 可选，自定义键值对
  author: example-org
  version: "1.0"
allowed-tools: Bash(git:*) Read  # 可选，预批准工具列表
---

# 正文：指令内容（无格式限制）
```

### 1.4 集成要求

一个 skills-compatible agent 需要：
1. **发现** — 扫描指定目录寻找有效 skill
2. **加载元数据** — 启动时仅解析 frontmatter 的 name/description
3. **匹配** — 将用户任务匹配到相关 skill
4. **激活** — 加载完整 SKILL.md 指令
5. **执行** — 访问 scripts/references/assets 资源

---

## 2. Kelivo 现有架构对比分析

### 2.1 现有相关机制

| 现有机制 | 与 Agent Skills 的关系 | 差异点 |
|---------|----------------------|--------|
| **InstructionInjection（指令注入）** | 最接近 — 都是向 system prompt 注入文本指令 | 指令注入是纯文本 prompt，无结构化元数据、无文件系统资源、无脚本 |
| **WorldBook（世界书）** | 条件触发式内容注入 | 世界书按关键词触发；Skills 按任务描述匹配 |
| **local_tools.json** | 工具声明与执行 | 本地工具侧重于 function calling 执行，Skills 侧重知识/工作流指令 |
| **MCP Server** | 外部工具连接 | MCP 是标准化工具协议；Skills 是指令/知识协议 |
| **Assistant presetMessages** | 系统提示模板 | 预设消息是静态的，Skills 是按需激活的 |

### 2.2 核心差距

1. **无文件系统 skill 发现机制** — 不能扫描目录自动发现 skills
2. **无 YAML frontmatter 解析** — 不能解析 `SKILL.md` 格式
3. **无动态匹配与激活** — 不能根据用户意图自动激活 skill
4. **无 script/reference/asset 资源访问** — 指令注入只有纯文本
5. **无渐进式加载** — 指令注入全量加载

---

## 3. 集成方案设计

### 3.1 总体架构

```
┌──────────────────────────────────────────────────────────────┐
│                    Agent Skills 集成层                        │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌────────────┐  │
│  │ Discovery │  │  Parser  │  │  Matcher  │  │  Injector   │  │
│  │  扫描发现  │→│ YAML解析  │→│ 意图匹配   │→│ 提示词注入   │  │
│  └──────────┘  └──────────┘  └───────────┘  └────────────┘  │
│        ↓                           ↑               ↓         │
│  ┌──────────┐              ┌───────────┐  ┌────────────┐    │
│  │  Store   │              │ Embedding │  │ Resource   │    │
│  │ 持久化    │              │ (可选)     │  │ Accessor   │    │
│  └──────────┘              └───────────┘  └────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 实现分层

#### Layer 1: 数据模型 (`lib/core/models/agent_skill.dart`)

```dart
/// Agent Skill 元数据（轻量，启动时加载）
class AgentSkillMeta {
  final String name;           // 1-64字符，小写+数字+连字符
  final String description;    // 1-1024字符
  final String? license;
  final String? compatibility;
  final Map<String, String> metadata;  // 自定义键值对
  final List<String> allowedTools;
  final String directoryPath;  // skill 目录的绝对路径
}

/// Agent Skill 完整内容（激活时加载）
class AgentSkill extends AgentSkillMeta {
  final String instructions;   // SKILL.md 正文（Markdown）
  final bool hasScripts;       // 是否有 scripts/ 目录
  final bool hasReferences;    // 是否有 references/ 目录
  final bool hasAssets;        // 是否有 assets/ 目录
}
```

#### Layer 2: SKILL.md 解析器 (`lib/core/services/agent_skills/skill_parser.dart`)

```dart
class SkillParser {
  /// 仅解析 frontmatter（用于启动发现阶段，~100 tokens）
  static AgentSkillMeta? parseMetadata(String skillMdContent, String dirPath);
  
  /// 解析完整内容（激活阶段）
  static AgentSkill? parseFull(String skillMdContent, String dirPath);
  
  /// 验证 name 格式
  static bool isValidName(String name);
  
  /// 验证 frontmatter
  static List<String> validate(String skillMdContent);
}
```

- YAML frontmatter 解析：使用 `yaml` 包（项目已有 `pubspec.yaml` 依赖管理）
- 正文提取：去除 `---` 分隔的 YAML 部分，剩余为 Markdown 指令

#### Layer 3: Skill 发现与存储 (`lib/core/services/agent_skills/skill_store.dart`)

```dart
class AgentSkillStore {
  /// 默认 skills 搜索目录
  /// - 应用数据目录: %APPDATA%/kelivo/skills/ (Windows)
  /// - 用户自定义目录（设置可配）
  
  /// 扫描所有配置的目录，返回有效 skill 元数据列表
  static Future<List<AgentSkillMeta>> discoverAll();
  
  /// 加载单个 skill 的完整内容
  static Future<AgentSkill?> loadFull(String directoryPath);
  
  /// 读取 skill 下的资源文件
  static Future<String?> readResource(String skillPath, String relativePath);
  
  /// 获取/设置 skill 搜索目录列表
  static Future<List<String>> getSearchDirectories();
  static Future<void> setSearchDirectories(List<String> paths);
  
  /// 获取/设置哪些 skills 被禁用
  static Future<Set<String>> getDisabledSkills();
  static Future<void> setDisabledSkills(Set<String> names);
  
  /// 按助手绑定的 skills
  static Future<List<String>> getActiveSkillsForAssistant(String? assistantId);
  static Future<void> setActiveSkillsForAssistant(String? assistantId, List<String> names);
}
```

#### Layer 4: 状态管理 (`lib/core/providers/agent_skill_provider.dart`)

```dart
class AgentSkillProvider with ChangeNotifier {
  List<AgentSkillMeta> _skills = [];          // 所有发现的 skills 元数据
  Map<String, AgentSkill> _loadedSkills = {}; // 已激活加载的完整 skills
  Set<String> _disabledSkills = {};           // 被禁用的 skill names
  Map<String, List<String>> _activeByAssistant = {}; // 按助手绑定
  
  /// 初始化：扫描目录、加载元数据
  Future<void> initialize();
  
  /// 刷新 skills 列表（重新扫描）
  Future<void> refresh();
  
  /// 获取助手可用的 skills
  List<AgentSkillMeta> availableFor(String? assistantId);
  
  /// 激活 skill（加载完整内容）
  Future<AgentSkill?> activate(String name);
  
  /// 启用/禁用 skill
  Future<void> toggleSkill(String name, bool enabled);
  
  /// 为助手绑定/解绑 skill
  Future<void> setActiveForAssistant(String? assistantId, List<String> names);
}
```

#### Layer 5: 提示词注入 — 修改 `MessageBuilderService`

在现有提示词注入流水线中新增一个阶段：

```
现有流程:
  injectSystemPrompt() → injectMemory() → injectSearch() 
  → injectInstructionPrompts() → injectWorldBookPrompts()
  
新增:
  injectSystemPrompt() → injectMemory() → injectSearch() 
  → injectInstructionPrompts() → ★ injectAgentSkillPrompts() ★
  → injectWorldBookPrompts()
```

```dart
/// 在 MessageBuilderService 中新增
Future<void> injectAgentSkillPrompts(
  List<Map<String, dynamic>> apiMessages,
  String? assistantId,
) async {
  final provider = contextProvider.read<AgentSkillProvider>();
  final activeNames = provider.availableFor(assistantId)
      .where((s) => !provider._disabledSkills.contains(s.name))
      .toList();
  
  if (activeNames.isEmpty) return;
  
  // 方案 A：直接注入所有活跃 skill 的指令（简单）
  // 方案 B：注入 <available_skills> XML 元数据，让 LLM 决定使用哪个（推荐）
  
  // 采用混合方案：
  // 1. 始终注入 <available_skills> XML（轻量元数据）
  // 2. 被助手明确绑定的 skills → 直接注入完整指令
  // 3. 全局可用但未绑定的 skills → 仅元数据，LLM 可通过工具读取

  final boundNames = provider.activeSkillNamesFor(assistantId).toSet();
  
  final buffer = StringBuffer();
  
  // 注入已绑定 skills 的完整指令
  for (final name in boundNames) {
    final skill = await provider.activate(name);
    if (skill != null) {
      buffer.writeln('\n<skill name="${skill.name}">');
      buffer.writeln(skill.instructions);
      buffer.writeln('</skill>');
    }
  }
  
  // 注入未绑定 skills 的元数据索引
  final unbound = activeNames.where((s) => !boundNames.contains(s.name));
  if (unbound.isNotEmpty) {
    buffer.writeln('\n<available_skills>');
    for (final s in unbound) {
      buffer.writeln('  <skill>');
      buffer.writeln('    <name>${s.name}</name>');
      buffer.writeln('    <description>${s.description}</description>');
      buffer.writeln('  </skill>');
    }
    buffer.writeln('</available_skills>');
  }
  
  if (buffer.isNotEmpty) {
    _appendToSystemMessage(apiMessages, buffer.toString());
  }
}
```

#### Layer 6: UI 界面

##### 6a. Skills 管理页面 (`lib/features/skills/`)

```
features/skills/
├── pages/
│   ├── skills_list_page.dart      # Skills 列表（卡片展示）
│   ├── skill_detail_page.dart     # Skill 详情（查看/预览 SKILL.md）
│   └── skill_directories_page.dart # 管理搜索目录
└── widgets/
    ├── skill_card.dart            # Skill 卡片组件
    ├── skill_toggle.dart          # 启用/禁用开关
    └── skill_directory_picker.dart # 目录选择器
```

##### 6b. 助手编辑页中集成

在现有助手编辑页面（绑定 MCP/指令注入的位置附近）新增 "Skills" 选项卡：
- 列出所有可用 skills
- 勾选绑定到当前助手
- 显示已绑定 skills 数量徽章

##### 6c. 设置页集成

在全局设置中新增 "Agent Skills" 区域：
- Skills 搜索目录管理（添加/移除目录路径）
- 全局启用/禁用开关
- 刷新按钮（重新扫描）
- Skills 数量统计

---

## 4. 实现计划（分阶段）

### Phase 1: 基础框架（核心功能）

| 步骤 | 任务 | 文件 | 优先级 |
|------|------|------|--------|
| 1.1 | 添加 `yaml` 依赖到 pubspec.yaml | `pubspec.yaml` | P0 |
| 1.2 | 创建 `AgentSkillMeta` / `AgentSkill` 数据模型 | `lib/core/models/agent_skill.dart` | P0 |
| 1.3 | 实现 `SkillParser` (YAML frontmatter 解析 + 验证) | `lib/core/services/agent_skills/skill_parser.dart` | P0 |
| 1.4 | 实现 `AgentSkillStore` (目录扫描 + 持久化) | `lib/core/services/agent_skills/skill_store.dart` | P0 |
| 1.5 | 实现 `AgentSkillProvider` (状态管理) | `lib/core/providers/agent_skill_provider.dart` | P0 |
| 1.6 | 在 `main.dart` 注册 Provider | `lib/main.dart` | P0 |
| 1.7 | 在 `MessageBuilderService` 添加 `injectAgentSkillPrompts()` | `lib/features/home/services/message_builder_service.dart` | P0 |
| 1.8 | 在 `MessageGenerationService` 流水线中插入调用 | `lib/features/home/services/message_generation_service.dart` | P0 |

### Phase 2: UI 集成

| 步骤 | 任务 | 文件 | 优先级 |
|------|------|------|--------|
| 2.1 | 创建 Skills 列表页面 | `lib/features/skills/pages/skills_list_page.dart` | P1 |
| 2.2 | 创建 Skill 详情页（查看 SKILL.md 渲染） | `lib/features/skills/pages/skill_detail_page.dart` | P1 |
| 2.3 | Skill 目录管理页面 | `lib/features/skills/pages/skill_directories_page.dart` | P1 |
| 2.4 | 助手编辑页添加 Skills 选项卡 | 修改现有助手编辑页 | P1 |
| 2.5 | 全局设置页集成入口 | 修改 settings pages | P1 |
| 2.6 | 添加国际化文本 (zh/en) | `lib/l10n/app_zh.arb`, `app_en.arb` | P1 |

### Phase 3: 高级功能

| 步骤 | 任务 | 说明 | 优先级 |
|------|------|------|--------|
| 3.1 | Script 执行支持 | 在 `FunctionRouter` / `ToolRegistry` 中注册 skill 的 `scripts/` 为可调用工具 | P2 |
| 3.2 | 资源文件读取工具 | 注册 `read_skill_resource` 工具，让 LLM 按需读取 `references/` 和 `assets/` | P2 |
| 3.3 | LLM 动态激活 | 向 LLM 暴露 `activate_skill` 工具，允许根据对话上下文动态加载 skill 指令 | P2 |
| 3.4 | Skill 导入/导出 | 从 GitHub URL / ZIP 导入 skill | P2 |
| 3.5 | Skill 市场集成 | 浏览/搜索/安装社区 skills | P3 |
| 3.6 | Skill 创建向导 | 在应用内创建/编辑 SKILL.md | P3 |

---

## 5. 技术决策与注意事项

### 5.1 依赖

| 包 | 用途 | 说明 |
|---|------|------|
| `yaml` | 解析 SKILL.md frontmatter | 纯 Dart，无平台限制 |
| `path` | 跨平台路径处理 | 已隐式依赖 |

### 5.2 Skills 搜索路径（默认）

| 平台 | 路径 |
|------|------|
| Windows | `%APPDATA%/kelivo/skills/` |
| macOS | `~/Library/Application Support/kelivo/skills/` |
| Linux | `~/.config/kelivo/skills/` |
| Android/iOS | App Documents 目录下的 `skills/` |

用户可在设置中添加额外搜索路径。

### 5.3 安全考量

1. **Script 执行沙箱** — Phase 3 中执行 `scripts/` 时需要：
   - 用户确认对话框
   - 可配置的 allowed/blocked 列表
   - 执行日志记录
2. **路径遍历防护** — 读取 skill 资源时验证路径不超出 skill 目录
3. **大小限制** — 单个 SKILL.md 建议 < 500 行；总 skill 数量无硬限制但警告过多

### 5.4 与现有机制的关系

| 场景 | 推荐机制 |
|------|---------|
| 简单文本指令 | InstructionInjection（指令注入） |
| 按关键词触发的知识条目 | WorldBook（世界书） |
| 结构化的专业工作流 + 脚本 + 参考资料 | **Agent Skills** |
| 外部 API/工具调用 | MCP / local_tools.json |
| 短期预设对话 | Assistant presetMessages |

Agent Skills 不替代现有机制，而是补充：适合**复杂、自包含的专业知识模块**。

### 5.5 渐进式加载策略

```
启动时:
  skills/ 目录扫描 → 每个 SKILL.md 仅解析 frontmatter
  → 存入内存 Map<name, AgentSkillMeta>      (~100 tokens/skill)
  
发送消息时:
  已绑定助手的 skills → 加载完整 SKILL.md body → 注入 system prompt
  未绑定的 skills → 以 <available_skills> XML 注入元数据索引
  
LLM 请求时 (Phase 3):
  LLM 可调用 activate_skill(name) → 动态加载指令到上下文
  LLM 可调用 read_skill_resource(name, path) → 读取参考文档
```

---

## 6. 文件清单（Phase 1 新增）

```
lib/
├── core/
│   ├── models/
│   │   └── agent_skill.dart                    # NEW: 数据模型
│   ├── providers/
│   │   └── agent_skill_provider.dart           # NEW: 状态管理
│   └── services/
│       └── agent_skills/
│           ├── skill_parser.dart               # NEW: YAML 解析
│           └── skill_store.dart                # NEW: 发现 + 存储
├── features/
│   └── home/services/
│       ├── message_builder_service.dart        # MODIFY: 添加注入方法
│       └── message_generation_service.dart     # MODIFY: 调用新注入
└── main.dart                                   # MODIFY: 注册 Provider

pubspec.yaml                                    # MODIFY: 添加 yaml 依赖
```

---

## 7. 兼容 VS Code Copilot Skills 对照

当前项目 `.copilot/skills/` 下已有大量 VS Code Copilot 使用的 skills（如 `flutter-expert`, `react-expert` 等），其格式与 Agent Skills 规范高度一致（都使用 SKILL.md + YAML frontmatter + Markdown body）。

kelivo 的 Agent Skills 实现可以兼容读取这些 skills，使用户可以复用已有的 skill 生态。

---

## 8. 总结

Agent Skills 集成为 kelivo 提供了一种**标准化、可分享、可组合**的知识扩展格式。通过分三个阶段实现，Phase 1 可在 1-2 周内完成核心功能，让用户能够：

1. 将 `SKILL.md` 文件放入指定目录
2. 在助手设置中绑定 skills
3. 对话时自动获得 skill 的专业知识和工作流指令

后续阶段将增加脚本执行、动态激活、社区市场等高级功能。
