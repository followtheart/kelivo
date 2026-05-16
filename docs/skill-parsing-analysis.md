# Kelivo Skill 解析与提取机制分析

> 分析对象：Kelivo 项目对 Agent Skill 的解释方式，以及如何从 Skill 中提取脚本、工具、资源等内容。

## 一、Skill 的规范基础

项目实现的是 [Agent Skills 开放规范](https://agentskills.io/specification)。每个 Skill 是一个**目录**，结构如下：

```
skill-name/
├── SKILL.md         # 必需：YAML frontmatter + Markdown 正文
├── scripts/         # 可选：可执行脚本
├── references/      # 可选：参考文档
└── assets/          # 可选：模板/资源文件
```

## 二、核心代码文件

| 文件 | 职责 |
|---|---|
| `lib/core/models/agent_skill.dart` | 数据模型 `AgentSkillMeta` / `AgentSkill`（两层模型） |
| `lib/core/services/agent_skills/skill_parser.dart` | SKILL.md 解析、frontmatter 拆分、字段校验 |
| `lib/core/services/agent_skills/skill_store.dart` | 目录扫描、持久化、资源安全读取 |
| `lib/core/services/agent_skills/skill_tool_service.dart` | 把 Skill 能力暴露为 LLM 工具 |
| `lib/core/services/agent_skills/skill_import_export.dart` | ZIP / GitHub 导入导出 |
| `lib/core/providers/agent_skill_provider.dart` | 全局状态、激活缓存、按助手绑定 |
| `lib/features/home/services/message_builder_service.dart` | 把 Skill 注入到 system prompt |

## 三、两层数据模型（节省 token）

`agent_skill.dart:15-102`、`agent_skill.dart:108-169`

- **`AgentSkillMeta`（轻量元数据，启动时全量加载，每个约 100 tokens）**
  - `name`, `description`, `license`, `compatibility`, `metadata`, `allowedTools`, `directoryPath`
- **`AgentSkill`（继承自 Meta，激活时才加载，建议 <5000 tokens）**
  - 额外字段：`instructions`（Markdown 正文）、`hasScripts` / `hasReferences` / `hasAssets`（资源目录存在标志）

## 四、SKILL.md 的解析流程

`skill_parser.dart`：

1. **Frontmatter 拆分** `_splitFrontmatter` (149-166)
   - 用 `---` 起止 + 正则 `^---\s*$` 多行匹配，分离出 frontmatter 与 body
2. **YAML 解析** `_parseYaml` (169-180)
   - 用 `yaml` 包的 `loadYaml`，递归把 `YamlMap` 转 `Map<String, dynamic>`
3. **字段提取与校验**
   - `name`：必填，正则 `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`，长度 1-64，不允许 `--` 或首尾连字符（`isValidName` 87-92）
   - `description`：必填，≤ 1024 字符
   - `compatibility`：≤ 500 字符
   - `metadata`：任意 K-V Map
   - `allowed-tools`：**支持三种形式**（`_parseAllowedTools` 213-226）
     - YAML 列表 `[Tool1, Tool2]`
     - 空格分隔字符串 `"Tool1 Tool2"`
     - 注：parser 实际只按 `\s+` 拆分，逗号需是分隔符的话由 YAML 列表表达
4. **资源目录检测**（`parseFull` 62-69）
   - 同步检查 `scripts/`、`references/`、`assets/` 目录是否存在，设置三个布尔标志
5. **两个入口**
   - `parseMetadata()`：只解 frontmatter，启动时批量调用
   - `parseFull()`：包含 body + 资源目录检测，仅在激活时调用

## 五、Skill 内"脚本/工具/资源"的提取方式

项目把 Skill 包含的内容分成 **3 类**，分别用不同手段提取：

### 1) Tools（声明式）

- 来源：`allowed-tools` frontmatter 字段
- 解析方式：`SkillParser._parseAllowedTools` 在解析阶段直接转成 `List<String>`，存到 `allowedTools` 字段
- 用途：仅作为元数据展示和系统提示注入；**实际工具仍由 Kelivo 自身工具系统提供**

### 2) Scripts（动态发现）

不是在解析时枚举脚本文件，而是：

- 解析时：仅记一个布尔位 `hasScripts`（`scripts/` 目录是否存在）
- 激活时：`_handleActivateSkill` (`skill_tool_service.dart:245-264`) **遍历 `scripts/`、`references/`、`assets/` 目录**（`Directory.list(recursive: true)`），把所有文件以相对路径列入返回结果给 LLM
- 执行时：`_handleRunScript` (`skill_tool_service.dart:308-451`) 按扩展名分派解释器：
  - Windows：`.py→python`、`.ps1→powershell -ExecutionPolicy Bypass`、`.bat/.cmd→cmd /c`、`.js/.mjs→node`、`.sh→bash`
  - Linux/macOS：`.py→python3`、`.js/.mjs→node`、其它先 `chmod +x` 再直接执行
  - 60 秒超时，stdout 截断 8000 字符，stderr 截断 4000 字符
- 安全：用 `p.isWithin` 防路径穿越，脚本必须位于 `scripts/` 子目录内（330-337 行）

### 3) Resources（references / assets，按需读取）

- `_handleReadResource` (`skill_tool_service.dart:279-305`) → `AgentSkillStore.readResource` 同样做路径穿越保护
- 文件清单同样在 activate 时一并返回给 LLM

## 六、暴露给 LLM 的三个工具

`skill_tool_service.dart:53-77` 根据当前状态动态构建 OpenAI function-calling 格式的工具定义：

| 工具 | 时机 | 作用 |
|---|---|---|
| `activate_skill(name)` | 总是注入（若有 Skill） | 加载 Skill 全文 + 列出资源文件 |
| `read_skill_resource(skill_name, path)` | 总是注入 | 读取 references/assets 中的文件 |
| `run_skill_script(skill_name, script, args[])` | 仅当存在 `hasScripts==true` 的 Skill 时注入 | 执行 scripts/ 中的脚本 |

## 七、注入到 System Prompt 的渐进式策略

`message_builder_service.dart` 的 `injectAgentSkillPrompts`：

- **绑定到当前助手的 Skill**：把完整 `instructions` 包在 `<skills>` 内（LLM 直接可用）
- **未绑定但启用的 Skill**：仅以轻量 `<available_skills>` 形式注入

  ```xml
  <available_skills>
    <skill name="..." description="..." tools="..." />
  </available_skills>
  ```

  LLM 看到后可调用 `activate_skill` 按需加载——这就是规范里"渐进披露"（progressive disclosure）的实现。

## 八、发现与持久化

`skill_store.dart`：

- 默认搜索目录：Kelivo 应用目录 + `~/.copilot/skills` + `%APPDATA%/.copilot/skills`
- `discoverAll()` 扫描所有目录下"含 SKILL.md 的子目录"，重名只保留首个
- 持久化（SharedPreferences）：搜索目录列表、被禁用的 Skill、每个助手绑定的 Skill 名

## 总结

Kelivo 的 Skill 解析采用 **"两层模型 + 渐进披露"** 的设计：解析时只读 YAML frontmatter 拿到声明式的 `allowed-tools` 与 `metadata`，并用目录存在性快速判断是否有 `scripts/`、`references/`、`assets/`；真正的脚本文件清单在 `activate_skill` 工具被调用时才递归枚举，脚本执行通过 `run_skill_script` 按扩展名分派解释器并做路径穿越防护。
