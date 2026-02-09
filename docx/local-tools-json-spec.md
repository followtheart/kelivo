# Kelivo `local_tools.json` 格式说明书

> 版本：1.0 | 最后更新：2026-02-09

## 1. 概述

`local_tools.json` 是 Kelivo 的**本地工具注册配置文件**，用于以 JSON 格式声明本地可执行程序或命令行工具，使其能够被 LLM 通过 Function Calling 机制自动调用。

其设计借鉴了 MCP（Model Context Protocol）的工具定义协议，让用户无需修改源代码即可动态扩展可用工具集。

### 1.1 文件位置

| 环境 | 路径 |
|------|------|
| 开发 / 打包资源 | `assets/local_tools.json` |
| 运行时（首次启动自动拷贝到用户目录） | `<AppData>/kelivo/local_tools.json` |

### 1.2 加载时机

- 应用启动时，`FunctionRouter` 自动调用 `loadFromJsonFile()` 加载
- 支持运行时重新加载（调用 `loadFromJsonFile()` 即可热更新）
- 加载后，工具定义会合并进 `ToolRegistry`，与内置工具和 MCP 工具并列

---

## 2. 顶层结构

```jsonc
{
  "version": "1.0",                    // [必填] 配置文件版本号
  "description": "配置文件描述文字",      // [可选] 人类可读的说明
  "tools": [ ... ]                     // [必填] 工具定义数组
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|:----:|------|
| `version` | `string` | ✅ | 配置文件协议版本，当前为 `"1.0"` |
| `description` | `string` | ❌ | 配置文件的人类可读描述 |
| `tools` | `array<ToolDefinition>` | ✅ | 工具定义列表，见下文 |

---

## 3. 工具定义（ToolDefinition）

`tools` 数组中的每个元素为一个工具定义对象，完整字段如下：

```jsonc
{
  "name": "open_notepad",              // [必填] 工具唯一名称
  "description": "打开记事本",           // [必填] 工具描述（LLM 用此理解工具用途）
  "source": "local",                   // [可选] 工具来源，默认 "custom"
  "priority": 15,                      // [可选] 优先级，默认 100
  "safety": "safe",                    // [可选] 安全级别，默认 "safe"
  "requiredCapabilities": ["network"], // [可选] 所需能力列表
  "parameters": { ... },              // [可选] 参数 JSON Schema
  "executor": { ... }                 // [可选] 执行器配置
}
```

### 3.1 字段详解

#### `name` — 工具名称

| | |
|---|---|
| **类型** | `string` |
| **必填** | ✅ |
| **说明** | 工具的唯一标识符，LLM 调用时使用此名称。建议使用 `snake_case` 格式，如 `open_notepad`、`run_local_command`。名称不可与已注册的内置工具或 MCP 工具冲突。 |

#### `description` — 工具描述

| | |
|---|---|
| **类型** | `string` |
| **必填** | ✅（建议） |
| **默认值** | `""` |
| **说明** | 工具功能的自然语言描述。LLM 根据此描述决定何时调用该工具，因此应清晰、准确。支持中英文。 |

> **提示：** `description` 的质量直接影响 LLM 的工具选择准确率。建议包含：功能说明 + 适用场景 + 限制条件。

#### `source` — 工具来源

| | |
|---|---|
| **类型** | `string` (enum) |
| **必填** | ❌ |
| **默认值** | `"custom"` |
| **可选值** | `"builtin"` \| `"mcp"` \| `"local"` \| `"custom"` |

| 值 | 含义 |
|------|------|
| `builtin` | 内置工具（search、memory 等），通常不在此文件中定义 |
| `mcp` | MCP 服务器提供的工具，通常不在此文件中定义 |
| `local` | 本地程序/命令行工具（**推荐用于此文件**） |
| `custom` | 用户自定义工具 |

#### `priority` — 优先级

| | |
|---|---|
| **类型** | `integer` |
| **必填** | ❌ |
| **默认值** | `100` |
| **说明** | 数字**越小**优先级**越高**。当多个工具名称冲突时，按优先级排序。内置工具默认优先级为 `10`，建议本地工具设为 `15~50`。 |

#### `safety` — 安全级别

| | |
|---|---|
| **类型** | `string` (enum) |
| **必填** | ❌ |
| **默认值** | `"safe"` |
| **可选值** | `"safe"` \| `"confirm"` \| `"dangerous"` |

| 值 | 行为 |
|------|------|
| `safe` | ✅ 直接执行，无需用户确认 |
| `confirm` | ⚠️ 执行前弹窗请求用户确认 |
| `dangerous` | 🚫 直接拒绝执行，返回错误信息 |

> **注意：** 即使工具定义为 `safe`，如果运行时检测到调用的实际命令在内置黑名单中（如 `rm`、`del`、`format`），仍会被强制拦截。

#### `requiredCapabilities` — 所需能力

| | |
|---|---|
| **类型** | `array<string>` |
| **必填** | ❌ |
| **默认值** | `null` |
| **说明** | 预留字段，用于声明工具所需的系统能力（如 `"network"`、`"filesystem"`）。当前版本尚未做运行时校验。 |

---

## 4. `parameters` — 参数定义

参数定义遵循 **JSON Schema** 标准（draft-07），用于描述 LLM 调用工具时需传递的参数。该 Schema 会被直接发送给 LLM API。

### 4.1 结构

```jsonc
{
  "type": "object",
  "properties": {
    "参数名": {
      "type": "参数类型",
      "description": "参数描述"
    }
  },
  "required": ["必填参数名"]
}
```

### 4.2 支持的参数类型

| JSON Schema 类型 | 说明 | 示例 |
|------|------|------|
| `string` | 字符串 | 程序名、文件路径 |
| `integer` | 整数 | 端口号、超时秒数 |
| `number` | 数字（含浮点） | — |
| `boolean` | 布尔值 | 是否启用 shell |
| `array` | 数组 | 命令行参数列表 |
| `object` | 嵌套对象 | — |

### 4.3 内置的标准参数约定

以下参数名在 `LocalProgramHandler` 中有特殊处理逻辑：

| 参数名 | 类型 | 说明 |
|--------|------|------|
| `program` | `string` | 要执行的程序名或命令。如果 `executor.command` 未指定，则使用此值 |
| `args` | `array<string>` | 额外的命令行参数，追加在 `defaultArgs` 之后 |
| `file` | `string` | 要打开的文件路径，作为最后一个参数传给程序 |

> **参数合并顺序：** `executor.defaultArgs` → `arguments.args` → `arguments.file`

### 4.4 默认值

如果省略 `parameters` 字段，默认为：

```json
{
  "type": "object",
  "properties": {}
}
```

---

## 5. `executor` — 执行器配置

`executor` 字段定义工具的实际执行方式。当前支持 `local_program` 类型。

### 5.1 结构

```jsonc
{
  "type": "local_program",          // [必填] 执行器类型
  "mode": "launch",                 // [可选] 执行模式，默认 "launch"
  "command": "notepad.exe",         // [可选] 可执行文件名或完整路径
  "defaultArgs": [],                // [可选] 默认参数列表
  "workingDirectory": null,         // [可选] 工作目录
  "shell": false                    // [可选] 是否通过 shell 执行
}
```

### 5.2 字段详解

#### `type` — 执行器类型

| | |
|---|---|
| **类型** | `string` |
| **必填** | ✅ |
| **当前支持** | `"local_program"` |
| **说明** | 标识执行器的实现类型。当前版本仅支持 `local_program`（本地程序执行）。未来可扩展 `http_api`、`script` 等类型。 |

#### `mode` — 执行模式

| | |
|---|---|
| **类型** | `string` (enum) |
| **必填** | ❌ |
| **默认值** | `"launch"` |
| **可选值** | `"launch"` \| `"run"` |

| 模式 | 行为 | 适用场景 |
|------|------|---------|
| `launch` | 启动程序进程后**立即返回**，不等待输出。进程以 `detached` 模式运行 | 打开 GUI 程序（记事本、浏览器、VSCode 等） |
| `run` | 运行命令并**等待执行完成**，返回 stdout/stderr 输出 | 执行命令行工具（`dir`、`ipconfig`、`whoami` 等） |

#### `command` — 可执行文件

| | |
|---|---|
| **类型** | `string` |
| **必填** | ❌ |
| **说明** | 要执行的程序名或完整路径。如果省略，则使用运行时 `arguments.program` 参数的值。如果程序名在白名单中，会自动解析为实际可执行文件路径。 |

**程序名解析优先级：**

1. `arguments.program` → 首先检查调用参数
2. `executor.command` → 如果调用参数未提供，使用配置值
3. 白名单解析 → 将别名（如 `"chrome"`）映射为实际命令（如 `"chrome.exe"`）

#### `defaultArgs` — 默认参数

| | |
|---|---|
| **类型** | `array<string>` |
| **必填** | ❌ |
| **默认值** | `[]` |
| **说明** | 每次执行时自动附加的参数。运行时 `arguments.args` 会追加在其后。 |

#### `workingDirectory` — 工作目录

| | |
|---|---|
| **类型** | `string` |
| **必填** | ❌ |
| **默认值** | `null`（使用系统默认） |
| **说明** | 进程的工作目录，支持绝对路径。 |

#### `shell` — Shell 模式

| | |
|---|---|
| **类型** | `boolean` |
| **必填** | ❌ |
| **默认值** | `false` |
| **说明** | 是否通过系统 Shell 执行命令。设为 `true` 时，命令会通过 `cmd.exe`（Windows）/ `sh`（macOS/Linux）解释执行，可使用 Shell 内置命令（如 `dir`、`echo`）和管道、重定向等功能。 |

> **安全提示：** `shell: true` 允许 Shell 展开和管道操作，存在命令注入风险。建议仅对安全的预定义命令启用。

---

## 6. 安全机制

### 6.1 三级安全策略

```
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│   safe       │   │   confirm    │   │  dangerous   │
│  ✅ 直接执行  │   │ ⚠️ 需确认    │   │ 🚫 直接拒绝  │
└──────────────┘   └──────────────┘   └──────────────┘
```

### 6.2 内置白名单程序

白名单程序自动标记为 `safe`（无论配置文件如何定义）。各平台预设白名单：

<details>
<summary><b>Windows 白名单（点击展开）</b></summary>

| 别名 | 实际命令 |
|------|---------|
| `notepad` / `notepad.exe` | `notepad.exe` |
| `calc` / `calculator` | `calc.exe` |
| `mspaint` / `paint` | `mspaint.exe` |
| `explorer` | `explorer.exe` |
| `cmd` | `cmd.exe` |
| `powershell` | `powershell.exe` |
| `chrome` / `google chrome` | `chrome.exe` |
| `edge` / `microsoft edge` | `msedge.exe` |
| `firefox` | `firefox.exe` |
| `code` / `vscode` | `code.exe` |
| `taskmgr` / `task manager` | `taskmgr.exe` |
| `control` / `control panel` | `control.exe` |
| `regedit` | `regedit.exe` |
| `winver` | `winver.exe` |
| `osk` / `on-screen keyboard` | `osk.exe` |
| `magnify` / `magnifier` | `magnify.exe` |
| `charmap` / `character map` | `charmap.exe` |
| `snippingtool` / `snipping tool` | `SnippingTool.exe` |
| `wordpad` | `wordpad.exe` |
| `devmgmt.msc` / `device manager` | `devmgmt.msc` |

</details>

<details>
<summary><b>macOS 白名单（点击展开）</b></summary>

| 别名 | 实际应用名 |
|------|---------|
| `textedit` / `text edit` | `TextEdit` |
| `calculator` | `Calculator` |
| `preview` | `Preview` |
| `finder` | `Finder` |
| `safari` | `Safari` |
| `terminal` | `Terminal` |
| `chrome` / `google chrome` | `Google Chrome` |
| `firefox` | `Firefox` |
| `code` / `vscode` | `Visual Studio Code` |
| `notes` | `Notes` |
| `photos` | `Photos` |
| `music` | `Music` |
| `maps` | `Maps` |
| `activity monitor` | `Activity Monitor` |
| `system preferences` / `system settings` | `System Settings` |
| `reminders` | `Reminders` |

</details>

<details>
<summary><b>Linux 白名单（点击展开）</b></summary>

| 别名 | 实际命令 |
|------|---------|
| `gedit` / `text editor` | `gedit` |
| `nano` | `nano` |
| `vim` | `vim` |
| `calculator` / `gnome-calculator` | `gnome-calculator` |
| `nautilus` / `files` / `file manager` | `nautilus` |
| `terminal` / `gnome-terminal` | `gnome-terminal` |
| `firefox` | `firefox` |
| `chrome` / `google chrome` | `google-chrome` |
| `chromium` | `chromium-browser` |
| `code` / `vscode` | `code` |
| `eog` / `image viewer` | `eog` |
| `totem` / `video player` | `totem` |
| `evince` / `pdf viewer` | `evince` |

</details>

### 6.3 内置黑名单命令

以下命令**始终拒绝执行**，无论安全级别配置如何：

```
rm, rmdir, del, format, fdisk, mkfs, dd,
shutdown, reboot, halt, init,
kill, killall, taskkill,
net, netsh, reg, sfc, diskpart, bcdedit,
attrib, cipher
```

---

## 7. 完整示例

### 7.1 最小配置

```json
{
  "version": "1.0",
  "tools": [
    {
      "name": "open_notepad",
      "description": "打开记事本",
      "executor": {
        "type": "local_program",
        "command": "notepad.exe"
      }
    }
  ]
}
```

### 7.2 带参数的 GUI 程序

```json
{
  "name": "open_in_vscode",
  "description": "用 VS Code 打开指定文件或目录",
  "source": "local",
  "priority": 15,
  "safety": "safe",
  "parameters": {
    "type": "object",
    "properties": {
      "file": {
        "type": "string",
        "description": "要打开的文件或目录路径"
      }
    },
    "required": ["file"]
  },
  "executor": {
    "type": "local_program",
    "mode": "launch",
    "command": "code",
    "defaultArgs": [],
    "shell": false
  }
}
```

### 7.3 命令行工具（等待输出）

```json
{
  "name": "list_directory",
  "description": "列出指定目录下的文件和子目录",
  "source": "local",
  "priority": 15,
  "safety": "safe",
  "parameters": {
    "type": "object",
    "properties": {
      "args": {
        "type": "array",
        "items": { "type": "string" },
        "description": "dir 命令参数，如目标路径"
      }
    }
  },
  "executor": {
    "type": "local_program",
    "mode": "run",
    "command": "dir",
    "shell": true
  }
}
```

### 7.4 需要用户确认的命令

```json
{
  "name": "run_custom_script",
  "description": "运行自定义脚本",
  "source": "local",
  "priority": 30,
  "safety": "confirm",
  "parameters": {
    "type": "object",
    "properties": {
      "program": {
        "type": "string",
        "description": "脚本路径"
      },
      "args": {
        "type": "array",
        "items": { "type": "string" },
        "description": "脚本参数"
      }
    },
    "required": ["program"]
  },
  "executor": {
    "type": "local_program",
    "mode": "run",
    "shell": false
  }
}
```

### 7.5 完整多工具配置

```json
{
  "version": "1.0",
  "description": "我的自定义本地工具集",
  "tools": [
    {
      "name": "open_notepad",
      "description": "打开 Windows 记事本",
      "source": "local",
      "priority": 15,
      "safety": "safe",
      "parameters": {
        "type": "object",
        "properties": {
          "file": {
            "type": "string",
            "description": "可选：要打开的文件路径"
          }
        }
      },
      "executor": {
        "type": "local_program",
        "mode": "launch",
        "command": "notepad.exe"
      }
    },
    {
      "name": "get_system_info",
      "description": "获取当前系统的主机名、IP 地址等基本信息",
      "source": "local",
      "priority": 20,
      "safety": "safe",
      "parameters": {
        "type": "object",
        "properties": {
          "program": {
            "type": "string",
            "description": "要执行的信息命令，如 hostname、ipconfig、whoami"
          }
        },
        "required": ["program"]
      },
      "executor": {
        "type": "local_program",
        "mode": "run",
        "shell": true
      }
    }
  ]
}
```

---

## 8. 与 MCP 协议的对比

| 特性 | MCP 工具协议 | Kelivo `local_tools.json` |
|------|-------------|--------------------------|
| 传输方式 | JSON-RPC over stdio/SSE | 本地 JSON 文件 |
| 工具发现 | `tools/list` 方法 | 启动时读取文件 |
| 工具调用 | `tools/call` 方法 | `LocalProgramHandler.execute()` |
| 参数定义 | JSON Schema (`inputSchema`) | JSON Schema (`parameters`) |
| 安全机制 | 由 MCP 服务端实现 | 三级安全策略（白名单/确认/黑名单） |
| 执行环境 | 独立进程（MCP Server） | 直接 `Process.start` / `Process.run` |
| 热更新 | 重新连接 MCP Server | 重新调用 `loadFromJsonFile()` |

---

## 9. 字段速查表

| 字段 | 层级 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|:----:|--------|------|
| `version` | 顶层 | `string` | ✅ | — | 协议版本 |
| `description` | 顶层 | `string` | ❌ | — | 配置描述 |
| `tools` | 顶层 | `array` | ✅ | — | 工具列表 |
| `name` | tool | `string` | ✅ | — | 工具名称 |
| `description` | tool | `string` | ✅* | `""` | 工具描述 |
| `source` | tool | `enum` | ❌ | `"custom"` | 工具来源 |
| `priority` | tool | `int` | ❌ | `100` | 优先级 |
| `safety` | tool | `enum` | ❌ | `"safe"` | 安全级别 |
| `requiredCapabilities` | tool | `array` | ❌ | `null` | 所需能力 |
| `parameters` | tool | `object` | ❌ | `{}` | 参数 Schema |
| `executor` | tool | `object` | ❌ | `null` | 执行器配置 |
| `type` | executor | `string` | ✅ | — | 执行器类型 |
| `mode` | executor | `enum` | ❌ | `"launch"` | 执行模式 |
| `command` | executor | `string` | ❌ | — | 可执行文件 |
| `defaultArgs` | executor | `array` | ❌ | `[]` | 默认参数 |
| `workingDirectory` | executor | `string` | ❌ | `null` | 工作目录 |
| `shell` | executor | `boolean` | ❌ | `false` | Shell 模式 |

---

## 10. 常见问题

### Q: 如何让 LLM 更准确地调用我的工具？

**A:** 关键在于 `description` 字段。建议：
- 用自然语言清晰描述工具功能
- 说明适用场景（"当用户要求打开记事本时使用"）
- 说明限制条件（"仅支持 Windows"）
- 参数的 `description` 也要详细说明取值范围和示例

### Q: `command` 和 `program` 参数有什么区别？

**A:**
- `executor.command`：在配置文件中**静态指定**的命令，每次调用都用同一个
- `parameters.program`：由 LLM 在运行时**动态填入**的命令
- 如果两者都有，优先使用 `arguments.program`（来自 LLM 调用参数）

### Q: 如何添加 Shell 内置命令（如 `dir`、`echo`）？

**A:** 需要设置 `"shell": true`：
```json
{
  "executor": {
    "type": "local_program",
    "mode": "run",
    "command": "dir",
    "shell": true
  }
}
```

### Q: 工具名称有什么命名规范？

**A:** 建议遵循：
- 使用 `snake_case`（如 `open_notepad`、`run_local_command`）
- 不要与内置工具名冲突（`search`、`memory_read`、`memory_write` 等）
- 不要包含特殊字符或空格
- 名称应当具有描述性

### Q: 修改配置文件后需要重启应用吗？

**A:** 不需要。可以在应用中触发重新加载（目前需通过代码调用 `FunctionRouter.loadFromJsonFile()`）。未来计划支持 UI 层面的"刷新工具配置"操作。
