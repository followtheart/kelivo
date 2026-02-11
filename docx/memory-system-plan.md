# Kelivo 持久记忆系统 - 全面升级方案

> 基于 [Claude-Mem](https://docs.claude-mem.ai) 设计理念，结合 Kelivo 移动端 AI 聊天应用场景的记忆系统升级规划。

---

## 一、现状分析

### 1.1 当前架构

```
AssistantMemory (Model)
    ↓
MemoryStore (SharedPreferences, 全量 JSON)
    ↓
MemoryProvider (ChangeNotifier)
    ↓
UI: _MemoryTab (assistant_settings_edit_page.dart)
Tool: create_memory / edit_memory / delete_memory
```

### 1.2 当前数据模型

```dart
class AssistantMemory {
  final int id;           // 自增 ID
  final String assistantId; // 所属助手
  final String content;    // 记忆内容（纯文本）
}
```

### 1.3 问题总结

| 维度 | 现状 | 问题 |
|------|------|------|
| **数据模型** | 仅 `{id, assistantId, content}` | 无分类、无时间戳、无结构化元数据 |
| **存储** | `SharedPreferences` 全量 JSON | 无索引、无搜索、性能随数据量线性下降 |
| **写入** | 完全依赖 AI 主动调用 tool | 无自动捕获，AI 遗漏即丢失 |
| **检索** | 每次全量注入到 system prompt | token 浪费严重，记忆多时会撑爆上下文 |
| **范围** | 每个 assistant 独立，无全局记忆 | 用户偏好需每个 assistant 重复记录 |
| **隐私** | 无 | 无法排除敏感内容 |
| **生命周期** | 无 | 记忆没有过期、衰减、合并机制 |

---

## 二、新架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                      UI Layer                                │
│  ┌───────────────┐  ┌───────────────┐  ┌────────────────┐   │
│  │ MemoryMgmt    │  │ AssistantEdit │  │ ChatView       │   │
│  │ Page (新增)    │  │ Page (增强)    │  │ (记忆状态指示) │   │
│  └───────┬───────┘  └───────┬───────┘  └────────┬───────┘   │
│          │                  │                    │           │
├──────────┼──────────────────┼────────────────────┼───────────┤
│          ▼                  ▼                    ▼           │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              MemoryProvider (ChangeNotifier)         │    │
│  │  - memories / globalMemories / scopedMemories       │    │
│  │  - search(query) / getByCategory() / getImportant() │    │
│  │  - add() / update() / delete() / merge()            │    │
│  └─────────────────────────┬───────────────────────────┘    │
│                            │                                 │
├────────────────────────────┼─────────────────────────────────┤
│                            ▼                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              MemoryRepository                        │    │
│  │  - CRUD 操作                                        │    │
│  │  - FTS5 全文搜索                                     │    │
│  │  - 分类/范围查询                                      │    │
│  │  - Token 预算控制                                     │    │
│  └─────────────────────────┬───────────────────────────┘    │
│                            │                                 │
├────────────────────────────┼─────────────────────────────────┤
│                            ▼                                 │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              SQLite (drift)                          │    │
│  │  - memories 表                                       │    │
│  │  - conversation_summaries 表                         │    │
│  │  - memories_fts (FTS5 虚拟表)                        │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 数据模型

#### 2.2.1 Memory 表（核心记忆）

```sql
CREATE TABLE memories (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  scope         TEXT    NOT NULL DEFAULT 'assistant',  -- 'global' | 'assistant'
  assistant_id  TEXT,                                   -- NULL 表示全局记忆
  category      TEXT    NOT NULL DEFAULT 'fact',        -- 分类枚举
  content       TEXT    NOT NULL,                        -- 记忆内容
  source        TEXT    NOT NULL DEFAULT 'ai_tool',     -- 来源
  importance    INTEGER NOT NULL DEFAULT 3,             -- 重要性 1-5
  concepts      TEXT,                                    -- 标签 (逗号分隔)
  related_conversation_id TEXT,                          -- 关联对话 ID
  is_private    INTEGER NOT NULL DEFAULT 0,             -- 隐私标记
  created_at    INTEGER NOT NULL,                        -- 创建时间 (epoch ms)
  updated_at    INTEGER NOT NULL,                        -- 更新时间 (epoch ms)
  expires_at    INTEGER,                                 -- 过期时间 (epoch ms, NULL=永不过期)
  version       INTEGER NOT NULL DEFAULT 1              -- 版本号
);

-- 索引
CREATE INDEX idx_memories_scope ON memories(scope);
CREATE INDEX idx_memories_assistant ON memories(assistant_id);
CREATE INDEX idx_memories_category ON memories(category);
CREATE INDEX idx_memories_importance ON memories(importance DESC);
CREATE INDEX idx_memories_created ON memories(created_at DESC);
CREATE INDEX idx_memories_expires ON memories(expires_at);
```

**Category 枚举值：**

| 值 | 含义 | 示例 |
|----|------|------|
| `user_profile` | 用户个人信息 | 用户叫小明，25岁 |
| `preference` | 偏好设置 | 喜欢简洁回复、偏好中文 |
| `fact` | 事实性知识 | 用户的公司是 XX 科技 |
| `task` | 任务/计划 | 下周三要提交报告 |
| `decision` | 决策记录 | 选择了 React 而非 Vue |
| `learning` | 学习发现 | 用户正在学 Rust |
| `custom` | 自定义 | 其他未分类 |

**Source 枚举值：**

| 值 | 含义 |
|----|------|
| `ai_auto` | AI 在对话中自动提取 |
| `ai_tool` | AI 通过 tool call 写入 |
| `user_manual` | 用户手动添加 |
| `system` | 系统自动生成（如对话摘要提取） |

#### 2.2.2 ConversationSummary 表（对话摘要）

```sql
CREATE TABLE conversation_summaries (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id TEXT    NOT NULL,
  assistant_id    TEXT    NOT NULL,
  request         TEXT,                -- 用户请求摘要
  learned         TEXT,                -- 关键发现/学到了什么
  completed       TEXT,                -- 完成了什么
  next_steps      TEXT,                -- 后续建议
  created_at      INTEGER NOT NULL     -- 创建时间 (epoch ms)
);

CREATE INDEX idx_summaries_conversation ON conversation_summaries(conversation_id);
CREATE INDEX idx_summaries_assistant ON conversation_summaries(assistant_id);
CREATE INDEX idx_summaries_created ON conversation_summaries(created_at DESC);
```

#### 2.2.3 FTS5 全文搜索虚拟表

```sql
-- 记忆全文搜索
CREATE VIRTUAL TABLE memories_fts USING fts5(
  content,
  concepts,
  content='memories',
  content_rowid='id'
);

-- 自动同步触发器
CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, content, concepts)
  VALUES (new.id, new.content, new.concepts);
END;

CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, content, concepts)
  VALUES ('delete', old.id, old.content, old.concepts);
  INSERT INTO memories_fts(rowid, content, concepts)
  VALUES (new.id, new.content, new.concepts);
END;

CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, content, concepts)
  VALUES ('delete', old.id, old.content, old.concepts);
END;
```

### 2.3 Dart 数据模型

```dart
enum MemoryScope { global, assistant }

enum MemoryCategory {
  userProfile,
  preference,
  fact,
  task,
  decision,
  learning,
  custom,
}

enum MemorySource { aiAuto, aiTool, userManual, system }

class Memory {
  final int id;
  final MemoryScope scope;
  final String? assistantId;
  final MemoryCategory category;
  final String content;
  final MemorySource source;
  final int importance;        // 1-5
  final List<String> concepts; // 标签列表
  final String? relatedConversationId;
  final bool isPrivate;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final int version;
}

class ConversationSummary {
  final int id;
  final String conversationId;
  final String assistantId;
  final String? request;
  final String? learned;
  final String? completed;
  final String? nextSteps;
  final DateTime createdAt;
}
```

---

## 三、三层渐进式注入（核心设计）

借鉴 Claude-Mem 的 Progressive Disclosure 理念，将记忆注入从"全量灌入"改为"按需检索"。

### 3.1 注入流程

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: 自动注入 (对话开始)                                │
│  ────────────────────────────                                │
│  • 全局记忆中 importance >= 4 的条目                          │
│  • 当前助手记忆中 importance >= 4 的条目                      │
│  • 最近 3 条对话摘要 (仅 request + completed)                │
│  • Token 预算: ≤ 800 tokens                                  │
│                                                              │
│  注入格式:                                                    │
│  <memory_context>                                            │
│    <important_memories>                                      │
│      <m id="1" cat="user_profile">用户叫小明...</m>          │
│      <m id="5" cat="preference">偏好简洁回复</m>             │
│    </important_memories>                                     │
│    <recent_summaries>                                        │
│      <s date="2026-02-10">讨论了项目架构...</s>               │
│    </recent_summaries>                                       │
│    <stats total="42" injected="8" />                         │
│  </memory_context>                                           │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: 按需检索 (AI 调用 search_memory tool)              │
│  ────────────────────────────────────────────                 │
│  • AI 感知到需要更多上下文时，主动搜索                        │
│  • search_memory 返回匹配记忆的 ID + 摘要 (低 token 消耗)    │
│  • get_memory 批量获取完整内容 (仅对筛选后的 ID)              │
│  • 效果: 仅获取相关记忆，10x token 节省                      │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: 自动沉淀 (对话结束 / 后台)                         │
│  ────────────────────────────────────                         │
│  • AI 在对话中通过 tool 主动记录                              │
│  • 对话结束时生成 ConversationSummary                         │
│  • 定期任务: 合并重复记忆、降低过时记忆重要性                 │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Token 对比

| 场景 | 现方案 (全量注入) | 新方案 (渐进式) | 节省 |
|------|-------------------|-----------------|------|
| 10 条记忆 | ~500 tokens | ~300 tokens | 40% |
| 50 条记忆 | ~2,500 tokens | ~500 tokens | 80% |
| 200 条记忆 | ~10,000 tokens | ~600 tokens | 94% |
| 500 条记忆 | ~25,000 tokens (溢出) | ~700 tokens | 97% |

---

## 四、Tool 定义

### 4.1 写入类工具（增强现有）

```json
{
  "name": "create_memory",
  "description": "创建一条新的记忆记录",
  "parameters": {
    "type": "object",
    "properties": {
      "content":    { "type": "string",  "description": "记忆内容" },
      "category":   { "type": "string",  "enum": ["user_profile","preference","fact","task","decision","learning","custom"], "description": "分类" },
      "importance": { "type": "integer", "description": "重要性 1-5，默认 3", "minimum": 1, "maximum": 5 },
      "concepts":   { "type": "string",  "description": "标签，逗号分隔，如 'work,project'" },
      "scope":      { "type": "string",  "enum": ["global","assistant"], "description": "范围，默认 assistant" }
    },
    "required": ["content"]
  }
}

{
  "name": "edit_memory",
  "description": "更新一条记忆记录",
  "parameters": {
    "type": "object",
    "properties": {
      "id":         { "type": "integer", "description": "记忆 ID" },
      "content":    { "type": "string",  "description": "新内容" },
      "category":   { "type": "string",  "enum": [...] },
      "importance": { "type": "integer", "minimum": 1, "maximum": 5 },
      "concepts":   { "type": "string" }
    },
    "required": ["id"]
  }
}

{
  "name": "delete_memory",
  "description": "删除一条记忆记录",
  "parameters": {
    "type": "object",
    "properties": {
      "id": { "type": "integer", "description": "记忆 ID" }
    },
    "required": ["id"]
  }
}
```

### 4.2 检索类工具（新增）

```json
{
  "name": "search_memory",
  "description": "搜索记忆，返回匹配结果的 ID 和摘要列表（低 token 消耗）。当需要回忆之前的信息时使用。",
  "parameters": {
    "type": "object",
    "properties": {
      "query":    { "type": "string",  "description": "搜索关键词" },
      "category": { "type": "string",  "enum": [...], "description": "按分类筛选" },
      "scope":    { "type": "string",  "enum": ["global","assistant","all"], "description": "搜索范围" },
      "limit":    { "type": "integer", "description": "最大返回数，默认 10" }
    },
    "required": ["query"]
  }
}

{
  "name": "get_memory",
  "description": "根据 ID 列表批量获取完整记忆内容。先用 search_memory 找到相关 ID，再用此工具获取详情。",
  "parameters": {
    "type": "object",
    "properties": {
      "ids": { "type": "array", "items": { "type": "integer" }, "description": "记忆 ID 列表" }
    },
    "required": ["ids"]
  }
}
```

### 4.3 System Prompt 中的 Tool 使用引导

```text
## Memory System
你拥有持久记忆能力，通过以下工具管理：

### 已注入的重要记忆
上方 <memory_context> 中包含了高重要性记忆和最近对话摘要。

### 记忆工具
- `create_memory`: 创建新记忆（支持分类、重要性、标签、范围）
- `edit_memory`: 更新已有记忆
- `delete_memory`: 删除过时记忆
- `search_memory`: 搜索记忆（先搜索，再按需获取）
- `get_memory`: 批量获取完整记忆内容

### 使用原则
1. **主动记录**: 在对话中主动识别并记录用户信息、偏好、计划等
2. **先搜后记**: 创建前先搜索是否已有相关记忆，避免重复
3. **合并更新**: 相似记忆应 edit 合并，而非重复 create
4. **分类标注**: 合理使用 category 和 concepts 便于检索
5. **重要性评估**: 核心用户信息 importance=5，临时信息 importance=1-2
6. **全局 vs 助手**: 用户通用信息用 scope=global，助手专属用 scope=assistant
7. **静默操作**: 无需告知用户你在操作记忆，除非用户主动询问
8. **隐私保护**: 不要记录敏感信息（民族、宗教、政治、犯罪记录等）
```

---

## 五、全局 vs 助手级记忆

### 5.1 设计

```
┌───────────────────────┐     ┌───────────────────────┐
│  全局记忆 (Global)     │     │  助手级记忆 (Scoped)   │
│  ────────────────      │     │  ──────────────────    │
│  scope = global        │     │  scope = assistant     │
│  assistantId = null    │     │  assistantId = xxx     │
│                        │     │                        │
│  • 用户姓名/昵称       │     │  • 该助手的对话偏好   │
│  • 年龄/性别/爱好      │     │  • 专属任务进度        │
│  • 通用偏好             │     │  • 领域特定知识        │
│  • 工作相关信息         │     │  • 上下文状态          │
└───────────┬───────────┘     └───────────┬───────────┘
            │                              │
            └────── 注入时合并 ────────────┘
                        ↓
              ┌─────────────────┐
              │ System Prompt   │
              │ 全局 + 当前助手  │
              └─────────────────┘
```

### 5.2 自动范围推断

当 AI 调用 `create_memory` 未指定 scope 时，系统可根据 category 自动推断：

| Category | 默认 Scope | 推理 |
|----------|-----------|------|
| `user_profile` | `global` | 用户信息跨助手共享 |
| `preference` | `assistant` | 偏好可能因助手而异 |
| `fact` | `global` | 事实通常是通用的 |
| `task` | `assistant` | 任务通常和特定助手上下文相关 |
| `decision` | `assistant` | 决策通常在特定对话上下文中 |
| `learning` | `global` | 学习发现通常是通用的 |

---

## 六、对话摘要自动生成

### 6.1 触发时机

```
对话结束（用户切换对话/关闭应用）
        ↓
检查当前对话是否有足够内容（≥ 3 轮对话）
        ↓
  ┌─ 是 → 生成摘要请求（轻量 API 调用）
  │        → 存入 conversation_summaries 表
  │
  └─ 否 → 跳过
```

### 6.2 摘要生成 Prompt

```text
请为以下对话生成简短摘要，格式如下：
- request: 用户的主要请求是什么（一句话）
- learned: 关键发现或信息（要点列表）
- completed: 完成了什么（要点列表）
- next_steps: 后续建议（可选）

对话内容:
{conversation_messages}
```

### 6.3 摘要注入格式

```xml
<recent_summaries>
  <summary date="2026-02-10" assistant="翻译助手">
    <request>翻译一篇关于 AI 的英文论文</request>
    <completed>完成了摘要和前三章的翻译</completed>
  </summary>
  <summary date="2026-02-09" assistant="编程助手">
    <request>重构记忆系统架构</request>
    <completed>设计了新的数据模型和渐进式注入方案</completed>
    <next_steps>开始 P0 存储迁移</next_steps>
  </summary>
</recent_summaries>
```

---

## 七、记忆生命周期管理

### 7.1 重要性衰减

```
定期检查（每次应用启动 / 每 24 小时）:
  - 超过 30 天未被引用且 importance <= 2 的记忆 → 标记为候选清理
  - 超过 90 天未更新且 importance <= 3 的记忆 → importance -= 1
  - importance 降至 0 → 自动归档/删除
  - importance >= 4 的记忆永不自动衰减
```

### 7.2 去重合并

```
AI 创建记忆时:
  1. 先 search_memory 查找相似内容
  2. 如有高相似度结果 → edit_memory 合并
  3. 无相似结果 → create_memory 新建

System prompt 引导:
  "相似或相关的记忆应合并为一条记录，而不要重复记录"
```

### 7.3 过期机制

```dart
// 任务类记忆可设置过期时间
create_memory(
  content: "下周三提交季度报告",
  category: "task",
  expiresAt: DateTime(2026, 2, 18),  // 下周三后自动过期
)

// 过期记忆在注入时自动跳过，定期清理
```

---

## 八、隐私控制

### 8.1 多层保护

```
┌─────────────────────────────────────────┐
│  Layer 1: AI Prompt 引导                │
│  "不要记录敏感信息（民族、宗教...）"     │
├─────────────────────────────────────────┤
│  Layer 2: isPrivate 标记                 │
│  用户可将记忆标记为私有，不再注入到     │
│  system prompt 但保留在数据库中         │
├─────────────────────────────────────────┤
│  Layer 3: 用户管理界面                   │
│  随时查看、编辑、删除任何记忆           │
├─────────────────────────────────────────┤
│  Layer 4: 导出与清空                     │
│  一键导出所有记忆 (JSON)                │
│  一键清空所有/指定助手的记忆            │
└─────────────────────────────────────────┘
```

---

## 九、UI 设计

### 9.1 记忆管理页面（新增独立页面）

```
┌─────────────────────────────────────────────────┐
│  ← 记忆管理                            [导出] ⋮ │
├─────────────────────────────────────────────────┤
│  [全局] [助手A] [助手B] [助手C]    ← Tab 切换   │
├─────────────────────────────────────────────────┤
│  🔍 搜索记忆...                                  │
│                                                  │
│  筛选: [全部▾] [用户信息] [偏好] [事实] [任务]    │
│  排序: [最近更新▾]                                │
├─────────────────────────────────────────────────┤
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ ⭐⭐⭐⭐⭐  👤 用户信息                     │  │
│  │ 用户叫小明，25岁，软件工程师，喜欢摄影     │  │
│  │ #profile #hobby  ·  AI自动  ·  2026-01-15 │  │
│  │                              [编辑] [删除]  │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ ⭐⭐⭐⭐  ⚙️ 偏好                          │  │
│  │ 偏好简洁直接的回复风格，喜欢代码示例       │  │
│  │ #style #code  ·  AI工具  ·  2026-02-01    │  │
│  │                              [编辑] [删除]  │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ ⭐⭐⭐  📋 任务               ⏰ 2月18日到期 │  │
│  │ 下周三需要提交季度报告                     │  │
│  │ #work  ·  AI工具  ·  2026-02-11           │  │
│  │                              [编辑] [删除]  │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│           ─ 共 42 条记忆 ─                       │
│                                                  │
│  [+ 手动添加记忆]                                │
├─────────────────────────────────────────────────┤
│  ⚠️ 清空全部记忆                                 │
└─────────────────────────────────────────────────┘
```

### 9.2 助手设置页记忆 Tab（增强现有）

```
┌─────────────────────────────────────────────────┐
│  记忆                                            │
├─────────────────────────────────────────────────┤
│  启用记忆            [====开关====]              │
│                                                  │
│  记忆注入预算         800 tokens ▾               │
│  自动生成对话摘要     [====开关====]              │
│  继承全局记忆         [====开关====]              │
│                                                  │
│  该助手的记忆: 12 条                              │
│  全局记忆: 8 条                                   │
│                                                  │
│  [管理该助手记忆 →]                               │
│  [管理全局记忆 →]                                 │
└─────────────────────────────────────────────────┘
```

---

## 十、数据迁移

### 10.1 从 SharedPreferences 迁移到 SQLite

```dart
/// 迁移策略: 应用启动时检查，仅执行一次
Future<void> migrateFromSharedPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString('assistant_memories_v1');
  if (raw == null) return; // 无旧数据

  final arr = jsonDecode(raw) as List;
  for (final item in arr) {
    final old = AssistantMemory.fromJson(item);
    await memoryRepo.insert(Memory(
      scope: MemoryScope.assistant,
      assistantId: old.assistantId,
      category: MemoryCategory.custom,   // 旧数据无分类，标记为 custom
      content: old.content,
      source: MemorySource.aiTool,
      importance: 3,                      // 默认重要性
      concepts: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  // 迁移完成，删除旧数据
  await prefs.remove('assistant_memories_v1');
  // 记录迁移已完成
  await prefs.setBool('memory_migrated_v2', true);
}
```

---

## 十一、技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| **数据库 ORM** | `drift` (moor) | 类型安全、代码生成、支持 FTS5、自动迁移 |
| **底层驱动** | `sqlite3_flutter_libs` | 跨平台 SQLite 支持 |
| **状态管理** | `ChangeNotifier` (现有) | 与项目现有架构一致 |
| **全文搜索** | SQLite FTS5 | 无需额外依赖，足够应对记忆数量级 |

> **为什么选 drift 而不是 sqflite?**
> - drift 提供类型安全的 Dart API，避免手写 SQL 字符串
> - 内置 schema 迁移系统
> - 原生支持 FTS5 虚拟表
> - 支持 DAOs (数据访问对象) 分层
> - 代码生成减少样板代码

---

## 十二、实施路线图

```
Phase 0 (P0) - 存储迁移                         🔴 高优先级
├── 引入 drift 依赖
├── 定义 memories 表 schema
├── 实现 MemoryRepository (CRUD)
├── 编写 SharedPreferences → SQLite 迁移
├── 更新 MemoryProvider 适配新 Repository
├── 更新 Tool Handler 适配新模型
└── 预计工时: 3-4 天

Phase 1 (P1) - 渐进式注入                       🔴 高优先级
├── 实现 Token 预算控制逻辑
├── 按 importance 选择性注入
├── 重构 injectMemoryAndRecentChats
├── 新增 search_memory / get_memory tool
├── 更新 System Prompt 引导
└── 预计工时: 2-3 天

Phase 2 (P2) - 全局记忆                          🟡 中优先级
├── Memory 模型增加 scope 字段
├── 全局/助手级记忆合并注入逻辑
├── 自动 scope 推断
├── UI: 助手设置页增加「继承全局记忆」开关
└── 预计工时: 1-2 天

Phase 3 (P3) - 全文搜索                          🟡 中优先级
├── 创建 FTS5 虚拟表 + 同步触发器
├── 实现 search 方法 (支持关键词/分类/范围)
├── search_memory tool 接入 FTS5
└── 预计工时: 1-2 天

Phase 4 (P4) - 对话摘要                          🟡 中优先级
├── 定义 conversation_summaries 表
├── 对话结束时触发摘要生成
├── 摘要注入到下次对话上下文
└── 预计工时: 2-3 天

Phase 5 (P5) - 生命周期管理                      🟢 低优先级
├── 过期机制实现
├── 重要性衰减定时任务
├── AI 辅助去重提示优化
└── 预计工时: 1-2 天

Phase 6 (P6) - UI 增强                           🟢 低优先级
├── 新增记忆管理独立页面
├── 分类筛选、搜索、排序
├── 重要性星级展示
├── 批量操作（删除/导出）
└── 预计工时: 2-3 天

Phase 7 (P7) - 隐私与导出                        🟢 低优先级
├── isPrivate 标记功能
├── 一键导出 (JSON)
├── 一键清空
├── 敏感分类黑名单
└── 预计工时: 1 天

总预计工时: 13-20 天
```

---

## 十三、风险与注意事项

1. **drift 引入成本**: drift 依赖代码生成 (`build_runner`)，会增加构建时间，需评估对 CI/CD 的影响
2. **迁移回退**: 需保留 SharedPreferences 旧数据一个版本周期，确保迁移失败可回退
3. **Token 预算调优**: 800 tokens 是建议值，需根据实际使用反馈调整
4. **对话摘要 API 成本**: 每次对话结束额外调一次 API 生成摘要，需评估成本与价值
5. **FTS5 中文分词**: SQLite FTS5 默认分词器对中文支持有限，可能需要 `simple` tokenizer 或考虑 `jieba` 等方案
6. **跨平台兼容**: `sqlite3_flutter_libs` 需确保在 iOS/Android/Windows/macOS/Linux/Web 全平台可用 (Web 需特殊处理)
