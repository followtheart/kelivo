import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/models.dart';

/// 本地程序执行处理器
///
/// 通过 `dart:io` 的 `Process` API 执行本地程序。
/// 支持两种模式：
/// - **launch**: 启动程序窗口并立即返回（如打开记事本）
/// - **run**: 运行命令并等待输出（如执行 `dir`）
///
/// ## 安全机制
///
/// 三级安全策略：
/// 1. **白名单程序** — 预设安全程序，直接执行
/// 2. **未知程序** — 标记为 `confirm`，执行前需用户确认
/// 3. **黑名单命令** — 标记为 `dangerous`，直接拒绝
///
/// ## JSON 注册协议
///
/// executor 配置字段：
/// ```json
/// {
///   "type": "local_program",
///   "mode": "launch",           // "launch" | "run"
///   "command": "notepad.exe",   // 可执行文件名或完整路径
///   "defaultArgs": [],          // 默认参数
///   "workingDirectory": null,   // 工作目录
///   "shell": false              // 是否通过 shell 执行
/// }
/// ```
class LocalProgramHandler {
  LocalProgramHandler();

  // ============================================================================
  // 安全策略
  // ============================================================================

  /// Windows 白名单程序 — 安全直接执行
  static const _windowsSafePrograms = <String, String>{
    'notepad': 'notepad.exe',
    'notepad.exe': 'notepad.exe',
    'calc': 'calc.exe',
    'calc.exe': 'calc.exe',
    'calculator': 'calc.exe',
    'mspaint': 'mspaint.exe',
    'mspaint.exe': 'mspaint.exe',
    'paint': 'mspaint.exe',
    'explorer': 'explorer.exe',
    'explorer.exe': 'explorer.exe',
    'snippingtool': 'SnippingTool.exe',
    'snipping tool': 'SnippingTool.exe',
    'wordpad': 'wordpad.exe',
    'wordpad.exe': 'wordpad.exe',
    'charmap': 'charmap.exe',
    'charmap.exe': 'charmap.exe',
    'character map': 'charmap.exe',
    'taskmgr': 'taskmgr.exe',
    'taskmgr.exe': 'taskmgr.exe',
    'task manager': 'taskmgr.exe',
    'control': 'control.exe',
    'control.exe': 'control.exe',
    'control panel': 'control.exe',
    'cmd': 'cmd.exe',
    'cmd.exe': 'cmd.exe',
    'powershell': 'powershell.exe',
    'powershell.exe': 'powershell.exe',
    'msedge': 'msedge.exe',
    'msedge.exe': 'msedge.exe',
    'edge': 'msedge.exe',
    'microsoft edge': 'msedge.exe',
    'chrome': 'chrome.exe',
    'chrome.exe': 'chrome.exe',
    'google chrome': 'chrome.exe',
    'firefox': 'firefox.exe',
    'firefox.exe': 'firefox.exe',
    'code': 'code.exe',
    'code.exe': 'code.exe',
    'vscode': 'code.exe',
    'visual studio code': 'code.exe',
    'winver': 'winver.exe',
    'winver.exe': 'winver.exe',
    'devmgmt.msc': 'devmgmt.msc',
    'device manager': 'devmgmt.msc',
    'regedit': 'regedit.exe',
    'regedit.exe': 'regedit.exe',
    'osk': 'osk.exe',
    'osk.exe': 'osk.exe',
    'on-screen keyboard': 'osk.exe',
    'magnify': 'magnify.exe',
    'magnify.exe': 'magnify.exe',
    'magnifier': 'magnify.exe',
  };

  /// macOS 白名单程序
  static const _macosSafePrograms = <String, String>{
    'textedit': 'TextEdit',
    'text edit': 'TextEdit',
    'calculator': 'Calculator',
    'preview': 'Preview',
    'finder': 'Finder',
    'safari': 'Safari',
    'terminal': 'Terminal',
    'activity monitor': 'Activity Monitor',
    'system preferences': 'System Preferences',
    'system settings': 'System Settings',
    'notes': 'Notes',
    'reminders': 'Reminders',
    'photos': 'Photos',
    'music': 'Music',
    'maps': 'Maps',
    'chrome': 'Google Chrome',
    'google chrome': 'Google Chrome',
    'firefox': 'Firefox',
    'vscode': 'Visual Studio Code',
    'visual studio code': 'Visual Studio Code',
    'code': 'Visual Studio Code',
  };

  /// Linux 白名单程序
  static const _linuxSafePrograms = <String, String>{
    'gedit': 'gedit',
    'text editor': 'gedit',
    'nano': 'nano',
    'vim': 'vim',
    'calculator': 'gnome-calculator',
    'gnome-calculator': 'gnome-calculator',
    'nautilus': 'nautilus',
    'files': 'nautilus',
    'file manager': 'nautilus',
    'terminal': 'gnome-terminal',
    'gnome-terminal': 'gnome-terminal',
    'firefox': 'firefox',
    'chrome': 'google-chrome',
    'google-chrome': 'google-chrome',
    'google chrome': 'google-chrome',
    'chromium': 'chromium-browser',
    'code': 'code',
    'vscode': 'code',
    'visual studio code': 'code',
    'eog': 'eog',
    'image viewer': 'eog',
    'totem': 'totem',
    'video player': 'totem',
    'evince': 'evince',
    'pdf viewer': 'evince',
  };

  /// 黑名单命令 — 危险操作，直接拒绝
  static const _dangerousCommands = <String>{
    'rm',
    'rmdir',
    'del',
    'format',
    'fdisk',
    'mkfs',
    'dd',
    'shutdown',
    'reboot',
    'halt',
    'init',
    'kill',
    'killall',
    'taskkill',
    'net',
    'netsh',
    'reg',
    'sfc',
    'diskpart',
    'bcdedit',
    'attrib',
    'cipher',
  };

  /// 获取当前平台的白名单
  static Map<String, String> get _safeProgramsForPlatform {
    if (Platform.isWindows) return _windowsSafePrograms;
    if (Platform.isMacOS) return _macosSafePrograms;
    if (Platform.isLinux) return _linuxSafePrograms;
    return {};
  }

  /// 解析程序名 — 查白名单，返回实际命令
  ///
  /// 返回 null 表示不在白名单中。
  static String? resolveSafeProgram(String input) {
    final key = input.trim().toLowerCase();
    return _safeProgramsForPlatform[key];
  }

  /// 检查命令是否在黑名单中
  static bool isDangerousCommand(String command) {
    final base = command.trim().toLowerCase().split(RegExp(r'[\\/]')).last;
    final nameNoExt = base.replaceAll(RegExp(r'\.(exe|bat|cmd|sh|ps1)$'), '');
    return _dangerousCommands.contains(nameNoExt);
  }

  /// 评估命令安全级别
  static ToolSafetyLevel evaluateSafety(String command) {
    if (isDangerousCommand(command)) return ToolSafetyLevel.dangerous;
    if (resolveSafeProgram(command) != null) return ToolSafetyLevel.safe;
    return ToolSafetyLevel.confirm;
  }

  // ============================================================================
  // 执行
  // ============================================================================

  /// 执行本地程序
  ///
  /// [toolName] — 工具名称
  /// [arguments] — 工具参数，支持的 key:
  ///   - `program` (`String`): 程序名或路径
  ///   - `args` (`List<String>`): 启动参数
  ///   - `file` (`String`): 要打开的文件路径
  /// [context] — 调用上下文
  /// [executorConfig] — 来自 ToolDefinition 的 executor 配置
  Future<ToolResult> execute(
    String toolName,
    Map<String, dynamic> arguments,
    ToolContext context, {
    Map<String, dynamic>? executorConfig,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      // 从 executorConfig 或 arguments 解析命令
      // executorConfig['command'] 是用户在 local_tools.json 中配置的完整可执行路径，
      // 优先级最高；arguments['program'] 是 LLM 传入的程序名/别名，作为 fallback。
      final configCommand = (executorConfig?['command'] ?? '').toString().trim();
      final argProgram = (arguments['program'] ??
              arguments['command'] ??
              arguments['cmd'] ??
              '')
          .toString()
          .trim();
      final rawProgram = configCommand.isNotEmpty ? configCommand : argProgram;

      // If command comes from LLM arguments (not from JSON config) and contains
      // spaces, split it into command + arguments (e.g. "dir /s /b" → "dir", ["/s", "/b"]).
      // NEVER split configCommand — it's a full executable path that may contain spaces
      // (e.g. "C:\Program Files (x86)\UltraISO\UltraISO.exe").
      String effectiveProgram = rawProgram;
      List<String> parsedArgs = [];
      if (configCommand.isEmpty &&
          rawProgram.contains(' ') &&
          arguments['args'] == null &&
          arguments['file'] == null) {
        final parts = _shellSplit(rawProgram);
        if (parts.isNotEmpty) {
          effectiveProgram = parts.first;
          parsedArgs = parts.sublist(1);
        }
      }

      if (effectiveProgram.isEmpty) {
        stopwatch.stop();
        return ToolResult.failure(
          'No program specified',
          executionTime: stopwatch.elapsed,
        );
      }

      // 安全检查
      if (isDangerousCommand(effectiveProgram)) {
        stopwatch.stop();
        return ToolResult.failure(
          'Command "$effectiveProgram" is blocked for safety reasons',
          executionTime: stopwatch.elapsed,
        );
      }

      // 解析实际命令
      final resolvedCommand = resolveSafeProgram(effectiveProgram) ?? effectiveProgram;

      // 构建参数列表
      final List<String> programArgs = [];

      // 来自 executorConfig 的默认参数
      if (executorConfig?['defaultArgs'] is List) {
        programArgs.addAll(
          (executorConfig!['defaultArgs'] as List).map((e) => e.toString()),
        );
      }

      // 从命令行拆分出的参数 (e.g. "dir /s /b" → parsedArgs=[/s, /b])
      if (parsedArgs.isNotEmpty) {
        programArgs.addAll(parsedArgs);
      }

      // 来自 arguments 的参数
      if (arguments['args'] is List) {
        programArgs.addAll(
          (arguments['args'] as List).map((e) => e.toString()),
        );
      }

      // file 参数 (兼容 file, file_path, filePath, filepath 等变体)
      final file = (arguments['file'] ??
              arguments['file_path'] ??
              arguments['filePath'] ??
              arguments['filepath'] ??
              '')
          .toString()
          .trim();
      if (file.isNotEmpty) {
        programArgs.add(file);
      }

      // 兼容 LLM 可能传入的其他常见参数名 (path, dir, directory, url, input)
      for (final altKey in ['path', 'dir', 'directory', 'url', 'input', 'target']) {
        final val = (arguments[altKey] ?? '').toString().trim();
        if (val.isNotEmpty) {
          programArgs.add(val);
        }
      }

      // 执行模式
      final mode = (executorConfig?['mode'] ?? 'launch').toString();
      final useShell = executorConfig?['shell'] == true;
      final workingDir =
          (executorConfig?['workingDirectory'] ?? '').toString().trim();

      debugPrint(
        '[LocalProgramHandler] Executing: $resolvedCommand '
        '${programArgs.isNotEmpty ? programArgs.join(" ") : ""} '
        '(mode=$mode, shell=$useShell)',
      );

      if (mode == 'run') {
        // run 模式 — 等待输出
        return await _executeRun(
          resolvedCommand,
          programArgs,
          stopwatch,
          useShell: useShell,
          workingDir: workingDir.isEmpty ? null : workingDir,
        );
      } else {
        // launch 模式 — 启动并立即返回
        return await _executeLaunch(
          resolvedCommand,
          programArgs,
          stopwatch,
          useShell: useShell,
          workingDir: workingDir.isEmpty ? null : workingDir,
        );
      }
    } catch (e) {
      stopwatch.stop();
      return ToolResult.failure(
        'Failed to execute program: $e',
        executionTime: stopwatch.elapsed,
      );
    }
  }

  /// Launch 模式 — 启动进程并立即返回
  Future<ToolResult> _executeLaunch(
    String command,
    List<String> args,
    Stopwatch stopwatch, {
    bool useShell = false,
    String? workingDir,
  }) async {
    if (Platform.isWindows) {
      // Windows: 使用 start 命令在新窗口中启动
      await Process.start(
        command,
        args,
        mode: ProcessStartMode.detached,
        runInShell: useShell,
        workingDirectory: workingDir,
      );
    } else if (Platform.isMacOS) {
      // macOS: 使用 open -a 启动应用
      await Process.start(
        'open',
        ['-a', command, ...args],
        mode: ProcessStartMode.detached,
        workingDirectory: workingDir,
      );
    } else {
      // Linux: 直接启动
      await Process.start(
        command,
        args,
        mode: ProcessStartMode.detached,
        runInShell: useShell,
        workingDirectory: workingDir,
      );
    }

    stopwatch.stop();
    return ToolResult.success(
      'Successfully launched "$command"'
      '${args.isNotEmpty ? ' with arguments: ${args.join(" ")}' : ''}',
      executionTime: stopwatch.elapsed,
    );
  }

  /// Run 模式 — 运行命令并收集输出
  Future<ToolResult> _executeRun(
    String command,
    List<String> args,
    Stopwatch stopwatch, {
    bool useShell = false,
    String? workingDir,
  }) async {
    final result = await Process.run(
      command,
      args,
      runInShell: useShell,
      workingDirectory: workingDir,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );

    stopwatch.stop();

    final stdout = (result.stdout ?? '').toString().trim();
    final stderr = (result.stderr ?? '').toString().trim();

    if (result.exitCode != 0) {
      return ToolResult.failure(
        'Command exited with code ${result.exitCode}.\n'
        '${stderr.isNotEmpty ? 'stderr: $stderr' : ''}'
        '${stdout.isNotEmpty ? '\nstdout: $stdout' : ''}',
        executionTime: stopwatch.elapsed,
      );
    }

    final output = StringBuffer();
    if (stdout.isNotEmpty) output.write(stdout);
    if (stderr.isNotEmpty) {
      if (output.isNotEmpty) output.write('\n');
      output.write('stderr: $stderr');
    }

    return ToolResult.success(
      output.isEmpty ? 'Command completed successfully (no output)' : output.toString(),
      executionTime: stopwatch.elapsed,
    );
  }

  // ============================================================================
  // 默认工具定义生成
  // ============================================================================

  /// 生成默认的本地程序工具定义列表（基于当前平台）
  ///
  /// 返回预置的安全工具，可直接注册到 ToolRegistry。
  static List<ToolDefinition> getDefaultLocalTools() {
    return [
      // 通用工具：打开任意本地程序
      const ToolDefinition(
        name: 'open_local_program',
        description:
            'Open a local program/application on the user\'s computer. '
            'Common programs: notepad, calculator (calc), paint (mspaint), '
            'explorer, browser (chrome/edge/firefox), terminal (cmd/powershell), '
            'vscode (code). You can also specify a file to open with the program.',
        parameters: {
          'type': 'object',
          'properties': {
            'program': {
              'type': 'string',
              'description':
                  'The program name or alias to open. '
                  'Examples: "notepad", "calc", "chrome", "explorer", '
                  '"cmd", "powershell", "code", "mspaint"',
            },
            'file': {
              'type': 'string',
              'description':
                  'Optional: file path to open with the program. '
                  'Example: "C:\\Users\\user\\document.txt"',
            },
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Optional: additional command line arguments',
            },
          },
          'required': ['program'],
        },
        source: ToolSource.local,
        priority: 15,
        safety: ToolSafetyLevel.safe,
        executorConfig: {
          'type': 'local_program',
          'mode': 'launch',
        },
      ),
      // 运行命令工具
      const ToolDefinition(
        name: 'run_local_command',
        description:
            'Run a local command and return its output. '
            'Use for getting system information, listing files, etc. '
            'Note: Dangerous commands (rm, del, format, etc.) are blocked.',
        parameters: {
          'type': 'object',
          'properties': {
            'program': {
              'type': 'string',
              'description':
                  'The command to run. '
                  'Examples: "dir", "echo", "whoami", "hostname", "ipconfig"',
            },
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Command arguments',
            },
          },
          'required': ['program'],
        },
        source: ToolSource.local,
        priority: 20,
        safety: ToolSafetyLevel.confirm,
        executorConfig: {
          'type': 'local_program',
          'mode': 'run',
          'shell': true,
        },
      ),
    ];
  }

  /// 将默认工具列表导出为 JSON（方便用户自定义）
  static String getDefaultLocalToolsJson() {
    final tools = getDefaultLocalTools();
    return const JsonEncoder.withIndent('  ')
        .convert(tools.map((t) => t.toJson()).toList());
  }

  /// Shell-aware string splitting that respects quoted segments.
  ///
  /// Examples:
  ///   `dir /s /b` → `['dir', '/s', '/b']`
  ///   `dir "%USERPROFILE%\Desktop" /s /b` → `['dir', '%USERPROFILE%\Desktop', '/s', '/b']`
  static List<String> _shellSplit(String input) {
    final result = <String>[];
    final buf = StringBuffer();
    String? quote; // current quote char (' or ")
    for (int i = 0; i < input.length; i++) {
      final c = input[i];
      if (quote != null) {
        if (c == quote) {
          quote = null; // closing quote — don't add quote char itself
        } else {
          buf.writeCharCode(c.codeUnitAt(0));
        }
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == ' ' || c == '\t') {
        if (buf.isNotEmpty) {
          result.add(buf.toString());
          buf.clear();
        }
      } else {
        buf.writeCharCode(c.codeUnitAt(0));
      }
    }
    if (buf.isNotEmpty) result.add(buf.toString());
    return result;
  }
}
