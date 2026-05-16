# `run_skill_script` 脚本执行机制详解

> 分析对象：`lib/core/services/agent_skills/skill_tool_service.dart` 中 `_handleRunScript`（308-451 行），详述脚本执行的两大机制——**路径穿越防护** 与 **按扩展名分派解释器**。

## 一、调用入口与参数

`run_skill_script` 是 OpenAI function-calling 格式的工具，参数定义见 136-169 行：

```jsonc
{
  "name": "run_skill_script",
  "parameters": {
    "skill_name": "string",     // 必填：Skill 名（不是路径）
    "script":     "string",     // 必填：scripts/ 下的文件名，例如 "setup.sh"
    "args":       "array<str>"  // 可选：传给脚本的参数
  }
}
```

LLM 只能指定 **`skill_name + script` 文件名**，不能直接给绝对路径——这是第一层防护：**接口设计层面就剥夺了任意路径访问能力**。

## 二、路径穿越防护（Path Traversal Protection）

源码 313-337 行：

```dart
final skillName = (args['skill_name'] ?? '').toString().trim();
final script    = (args['script']     ?? '').toString().trim();

// 1) 解析 Skill 元数据 → 拿到该 Skill 的目录绝对路径
final meta = provider.skills.where((s) => s.name == skillName).firstOrNull;
if (meta == null) return 'Error: skill "$skillName" not found.';

// 2) 强制把脚本路径拼到 scripts/ 子目录下
final scriptRelPath = p.join('scripts', script);
final scriptAbsPath = p.normalize(p.join(meta.directoryPath, scriptRelPath));

// 3) 关键：用 path.isWithin 校验解析后的绝对路径仍在 Skill 根目录内
if (!p.isWithin(meta.directoryPath, scriptAbsPath)) {
  return 'Error: path traversal detected — script must be in scripts/ directory.';
}

// 4) 文件存在性检查
final scriptFile = File(scriptAbsPath);
if (!await scriptFile.exists()) {
  return 'Error: script "$script" not found in skill "$skillName" scripts/ directory.';
}
```

防护要点：

| 防护手段 | 作用 |
|---|---|
| 通过 `provider.skills` 查询 `skillName` | 不让 LLM 直接传目录路径；只能使用已发现注册的 Skill |
| `p.join('scripts', script)` | 强制前缀 `scripts/`，即便 LLM 传 `script: "setup.sh"`，实际也是 `scripts/setup.sh` |
| `p.normalize(...)` | 规范化路径，**消解所有 `..` 和重复分隔符**，把 `scripts/../../../etc/passwd` 折叠为真实目标 |
| `p.isWithin(meta.directoryPath, scriptAbsPath)` | 校验归一化后的绝对路径**仍然位于 Skill 根目录之下**。如果归一化结果跳出了 Skill 根，则直接拒绝 |
| `File.exists()` | 拒绝指向不存在路径的调用（避免误执行） |

举几个攻击示例如何被阻断：

- `script: "../../../bin/sh"` → 拼成 `<skill>/scripts/../../../bin/sh` → 归一化为 `/bin/sh` → `isWithin` 返回 false → 拒绝
- `script: "../scripts/x.sh"` → 拼成 `<skill>/scripts/../scripts/x.sh` → 归一化为 `<skill>/scripts/x.sh` → 仍在 Skill 内 → 放行（这是合法等价路径）
- `script: "/etc/passwd"`（绝对路径）→ `p.join` 在多数实现里会以绝对路径覆盖前缀，但 `isWithin` 仍能把它拒绝

另外，整段执行用 `meta.directoryPath` 作为 `workingDirectory`（405-410 行），即便脚本内部使用相对路径，工作目录也被锁定在 Skill 根。

## 三、按扩展名分派解释器

源码 346-399 行。第一步取扩展名：

```dart
final ext = p.extension(scriptAbsPath).toLowerCase();
String executable;
List<String> cmdArgs;
```

然后按平台分两支：

### Windows 分支（350-378 行）

| 扩展名 | 解释器 | 实际命令行 |
|---|---|---|
| `.py` | `python` | `python <abs> <args...>` |
| `.ps1` | `powershell` | `powershell -ExecutionPolicy Bypass -File <abs> <args...>` |
| `.bat` / `.cmd` | `cmd` | `cmd /c <abs> <args...>` |
| `.js` / `.mjs` | `node` | `node <abs> <args...>` |
| `.sh` | `bash` | `bash <abs> <args...>`（依赖 Git Bash 或 WSL） |
| 其它 | 直接执行 `scriptAbsPath` | 假定该文件本身可执行 |

注意 `.ps1` 显式带 `-ExecutionPolicy Bypass`，是为了绕过 Windows 默认会阻止脚本运行的策略。

### macOS / Linux 分支（380-399 行）

| 扩展名 | 解释器 | 实际命令行 |
|---|---|---|
| `.py` | `python3` | `python3 <abs> <args...>` |
| `.js` / `.mjs` | `node` | `node <abs> <args...>` |
| 其它 | 先 `chmod +x <abs>`，再直接执行 | 让 shebang（`#!/bin/bash` 等）自行决定解释器 |

非 Windows 的"其它"分支会先尝试 `Process.run('chmod', ['+x', scriptAbsPath])`，给文件加上可执行权限。失败也吞掉异常（`try/catch (_)`），随后仍尝试执行——这是为了适配从 ZIP 解压出来时丢失可执行位的常见场景。

### 设计取舍

- **没有 Perl/Ruby/Deno 等**：项目只显式支持上面这几种主流脚本类型，其余都靠 shebang + 可执行位机制。
- **对 `.sh` 在 Windows 上要求 `bash` 在 PATH 中**：未做存在性检测，缺失时直接 `Process.run` 抛错。
- **不传环境变量过滤**：直接继承宿主进程环境。

## 四、执行与输出处理

源码 405-447 行：

```dart
final result = await Process.run(
  executable,
  cmdArgs,
  workingDirectory: meta.directoryPath,                  // 锁定到 Skill 根
  stderrEncoding: const Utf8Codec(allowMalformed: true), // 容错 UTF-8
  stdoutEncoding: const Utf8Codec(allowMalformed: true),
).timeout(
  const Duration(seconds: 60),
  onTimeout: () => ProcessResult(-1, -1, '', 'Script timed out after 60 seconds'),
);
```

执行后再处理：

- **60 秒硬超时**，超时返回 `exitCode=-1, stderr='Script timed out after 60 seconds'`
- `stdout` 截断 **8000 字符**，`stderr` 截断 **4000 字符**，避免污染 LLM 上下文
- 返回给 LLM 的格式：

  ```
  Script completed successfully (exit code: 0)

  --- stdout ---
  ...

  --- stderr ---
  ...
  ```

- 解释器或文件本身不存在等异常被 `try/catch` 包住，统一转成 `Error executing script: <e>` 字符串返回（448-450 行）。

## 五、整体安全护栏总结

| 层级 | 防护 |
|---|---|
| 接口层 | LLM 只能给 `skill_name + script` 文件名，无法传任意路径 |
| Skill 注册层 | `provider.skills` 必须包含该名字，否则拒绝 |
| 路径拼接层 | 强制前缀 `scripts/` |
| 路径归一化层 | `p.normalize` 折叠 `..` 与冗余分隔符 |
| 边界校验层 | `p.isWithin` 确认归一化结果仍在 Skill 根内 |
| 存在性层 | `File.exists()` 拒绝幽灵路径 |
| 工作目录层 | `workingDirectory` 锁定到 Skill 根 |
| 资源层 | 60 秒超时、stdout/stderr 截断 |
| 工具暴露层 | `buildToolDefinitions` 仅在至少一个 Skill 满足 `hasScripts==true` 时才注入 `run_skill_script`（74-76 行） |

## 总结

通过 **"接口剥夺路径权" + "强制前缀 + 归一化 + isWithin"** 三重防护实现路径穿越拦截；**按扩展名 + 平台二维分派表** 驱动解释器选择，对类 Unix 系统还兜底地 `chmod +x` 让 shebang 自行决定。
