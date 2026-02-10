import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../providers/agent_skill_provider.dart';
import 'skill_store.dart';

/// Service that exposes Agent Skills capabilities as LLM-callable tools.
///
/// Provides three tool definitions:
/// - `activate_skill` — dynamically load a skill's instructions into context
/// - `read_skill_resource` — read files from a skill's references/assets dirs
/// - `run_skill_script`  — execute a script from a skill's scripts/ dir
///
/// These tools enable the LLM to use Agent Skills progressively:
/// 1. See available skills via metadata in system prompt
/// 2. Activate a skill to load full instructions
/// 3. Read reference documents / assets as needed
/// 4. Run scripts for automated tasks (with user confirmation)
class AgentSkillToolService {
  AgentSkillToolService._();

  // ═══════════════════════════════════════════════════════════════════════════
  // Tool names (constants)
  // ═══════════════════════════════════════════════════════════════════════════

  static const String activateSkillToolName = 'activate_skill';
  static const String readSkillResourceToolName = 'read_skill_resource';
  static const String runSkillScriptToolName = 'run_skill_script';

  /// All tool names managed by this service.
  static const Set<String> managedToolNames = {
    activateSkillToolName,
    readSkillResourceToolName,
    runSkillScriptToolName,
  };

  /// Check if a tool name is managed by this service.
  static bool isSkillTool(String name) => managedToolNames.contains(name);

  // ═══════════════════════════════════════════════════════════════════════════
  // Tool Definitions (OpenAI function calling format)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Build all skill-related tool definitions.
  ///
  /// Only includes tools relevant to the current state:
  /// - `activate_skill` is always included when skills exist
  /// - `read_skill_resource` is included when skills with resources exist
  /// - `run_skill_script` is included when skills with scripts exist
  static List<Map<String, dynamic>> buildToolDefinitions(
    AgentSkillProvider provider,
  ) {
    final skills = provider.skills;
    if (skills.isEmpty) return const [];

    final defs = <Map<String, dynamic>>[];

    // Always include activate_skill
    defs.add(_activateSkillDefinition());

    // Include resource reader if any skill has references or assets
    defs.add(_readSkillResourceDefinition());

    // Include script runner if any enabled skill has scripts
    final hasScripts = skills.any((s) {
      final cached = provider.getCachedSkill(s.name);
      return cached?.hasScripts == true;
    });
    if (hasScripts) {
      defs.add(_runSkillScriptDefinition());
    }

    return defs;
  }

  static Map<String, dynamic> _activateSkillDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': activateSkillToolName,
        'description':
            'Activate an Agent Skill to load its full instructions into the '
            'current context. Use this when a skill listed in <available_skills> '
            'is relevant to the user\'s task. Returns the skill\'s detailed '
            'instructions, or an error if the skill is not found.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'The name of the skill to activate '
                  '(as shown in the available_skills list).',
            },
          },
          'required': ['name'],
        },
      },
    };
  }

  static Map<String, dynamic> _readSkillResourceDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': readSkillResourceToolName,
        'description':
            'Read a resource file from an activated Agent Skill\'s directory. '
            'Can read files from references/, assets/, or any other '
            'subdirectory within the skill folder. Use this to access '
            'reference documentation, templates, or data files that a skill '
            'provides.',
        'parameters': {
          'type': 'object',
          'properties': {
            'skill_name': {
              'type': 'string',
              'description': 'The name of the skill that owns the resource.',
            },
            'path': {
              'type': 'string',
              'description':
                  'Relative path to the resource file within the skill '
                  'directory (e.g. "references/api-guide.md" or '
                  '"assets/template.json").',
            },
          },
          'required': ['skill_name', 'path'],
        },
      },
    };
  }

  static Map<String, dynamic> _runSkillScriptDefinition() {
    return {
      'type': 'function',
      'function': {
        'name': runSkillScriptToolName,
        'description':
            'Execute a script from an activated Agent Skill\'s scripts/ '
            'directory. The script must exist within the skill\'s scripts/ '
            'folder. Use this for automated tasks the skill provides. '
            'Requires user approval before execution.',
        'parameters': {
          'type': 'object',
          'properties': {
            'skill_name': {
              'type': 'string',
              'description': 'The name of the skill that owns the script.',
            },
            'script': {
              'type': 'string',
              'description':
                  'Filename of the script within the skill\'s scripts/ '
                  'directory (e.g. "setup.sh" or "deploy.py").',
            },
            'args': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Arguments to pass to the script.',
            },
          },
          'required': ['skill_name', 'script'],
        },
      },
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Tool Execution
  // ═══════════════════════════════════════════════════════════════════════════

  /// Handle a skill tool call.
  ///
  /// Returns `null` if [toolName] is not a skill tool.
  static Future<String?> handleToolCall(
    String toolName,
    Map<String, dynamic> args,
    AgentSkillProvider provider,
  ) async {
    switch (toolName) {
      case activateSkillToolName:
        return _handleActivateSkill(args, provider);
      case readSkillResourceToolName:
        return _handleReadResource(args, provider);
      case runSkillScriptToolName:
        return _handleRunScript(args, provider);
      default:
        return null;
    }
  }

  /// activate_skill handler
  static Future<String> _handleActivateSkill(
    Map<String, dynamic> args,
    AgentSkillProvider provider,
  ) async {
    final name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return 'Error: skill name is required.';
    }

    // Check if skill exists
    final meta = provider.skills.where((s) => s.name == name).firstOrNull;
    if (meta == null) {
      final available = provider.skills.map((s) => s.name).join(', ');
      return 'Error: skill "$name" not found. Available skills: $available';
    }

    // Check if enabled
    if (!provider.isEnabled(name)) {
      return 'Error: skill "$name" is disabled by the user.';
    }

    // Load full content
    final skill = await provider.activate(name);
    if (skill == null) {
      return 'Error: failed to load skill "$name".';
    }

    // Build response with structured skill info
    final buf = StringBuffer();
    buf.writeln('# Skill: ${skill.name}');
    buf.writeln();
    buf.writeln('**Description:** ${skill.description}');
    if (skill.license != null) buf.writeln('**License:** ${skill.license}');
    if (skill.compatibility != null) {
      buf.writeln('**Compatibility:** ${skill.compatibility}');
    }
    if (skill.allowedTools.isNotEmpty) {
      buf.writeln('**Allowed tools:** ${skill.allowedTools.join(", ")}');
    }

    // List available resources
    final resources = <String>[];
    if (skill.hasScripts) resources.add('scripts/');
    if (skill.hasReferences) resources.add('references/');
    if (skill.hasAssets) resources.add('assets/');
    if (resources.isNotEmpty) {
      buf.writeln('**Available resources:** ${resources.join(", ")}');

      // List files in resource directories
      for (final resDir in resources) {
        try {
          final dirPath = p.join(skill.directoryPath, resDir);
          final dir = Directory(dirPath);
          if (await dir.exists()) {
            final files = <String>[];
            await for (final entity in dir.list(recursive: true)) {
              if (entity is File) {
                files.add(p.relative(entity.path, from: skill.directoryPath));
              }
            }
            if (files.isNotEmpty) {
              buf.writeln();
              buf.writeln('Files in $resDir:');
              for (final f in files) {
                buf.writeln('  - $f');
              }
            }
          }
        } catch (_) {}
      }
    }

    buf.writeln();
    buf.writeln('---');
    buf.writeln();
    buf.writeln('## Instructions');
    buf.writeln();
    buf.writeln(skill.instructions);

    return buf.toString();
  }

  /// read_skill_resource handler
  static Future<String> _handleReadResource(
    Map<String, dynamic> args,
    AgentSkillProvider provider,
  ) async {
    final skillName = (args['skill_name'] ?? '').toString().trim();
    final relativePath = (args['path'] ?? '').toString().trim();

    if (skillName.isEmpty) return 'Error: skill_name is required.';
    if (relativePath.isEmpty) return 'Error: path is required.';

    // Find skill
    final meta =
        provider.skills.where((s) => s.name == skillName).firstOrNull;
    if (meta == null) {
      return 'Error: skill "$skillName" not found.';
    }

    // Read resource with path traversal protection
    final content =
        await AgentSkillStore.readResource(meta.directoryPath, relativePath);
    if (content == null) {
      return 'Error: resource "$relativePath" not found in skill "$skillName", '
          'or access denied.';
    }

    return content;
  }

  /// run_skill_script handler
  static Future<String> _handleRunScript(
    Map<String, dynamic> args,
    AgentSkillProvider provider,
  ) async {
    final skillName = (args['skill_name'] ?? '').toString().trim();
    final script = (args['script'] ?? '').toString().trim();
    final scriptArgs = (args['args'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];

    if (skillName.isEmpty) return 'Error: skill_name is required.';
    if (script.isEmpty) return 'Error: script filename is required.';

    // Find skill
    final meta =
        provider.skills.where((s) => s.name == skillName).firstOrNull;
    if (meta == null) {
      return 'Error: skill "$skillName" not found.';
    }

    // Validate script path — must be under scripts/
    final scriptRelPath = p.join('scripts', script);
    final scriptAbsPath =
        p.normalize(p.join(meta.directoryPath, scriptRelPath));

    // Security: ensure the resolved path is within the skill directory
    if (!p.isWithin(meta.directoryPath, scriptAbsPath)) {
      return 'Error: path traversal detected — script must be in scripts/ directory.';
    }

    final scriptFile = File(scriptAbsPath);
    if (!await scriptFile.exists()) {
      return 'Error: script "$script" not found in skill "$skillName" scripts/ directory.';
    }

    // Execute the script
    try {
      final ext = p.extension(scriptAbsPath).toLowerCase();
      String executable;
      List<String> cmdArgs;

      if (Platform.isWindows) {
        switch (ext) {
          case '.py':
            executable = 'python';
            cmdArgs = [scriptAbsPath, ...scriptArgs];
            break;
          case '.ps1':
            executable = 'powershell';
            cmdArgs = ['-ExecutionPolicy', 'Bypass', '-File', scriptAbsPath, ...scriptArgs];
            break;
          case '.bat':
          case '.cmd':
            executable = 'cmd';
            cmdArgs = ['/c', scriptAbsPath, ...scriptArgs];
            break;
          case '.js':
          case '.mjs':
            executable = 'node';
            cmdArgs = [scriptAbsPath, ...scriptArgs];
            break;
          case '.sh':
            // Try Git Bash or WSL
            executable = 'bash';
            cmdArgs = [scriptAbsPath, ...scriptArgs];
            break;
          default:
            executable = scriptAbsPath;
            cmdArgs = scriptArgs;
        }
      } else {
        // macOS / Linux
        switch (ext) {
          case '.py':
            executable = 'python3';
            cmdArgs = [scriptAbsPath, ...scriptArgs];
            break;
          case '.js':
          case '.mjs':
            executable = 'node';
            cmdArgs = [scriptAbsPath, ...scriptArgs];
            break;
          default:
            // Make it executable and run directly
            try {
              await Process.run('chmod', ['+x', scriptAbsPath]);
            } catch (_) {}
            executable = scriptAbsPath;
            cmdArgs = scriptArgs;
        }
      }

      debugPrint(
        'AgentSkillToolService: Running script: $executable ${cmdArgs.join(" ")}',
      );

      final result = await Process.run(
        executable,
        cmdArgs,
        workingDirectory: meta.directoryPath,
        stderrEncoding: const Utf8Codec(allowMalformed: true),
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
      ).timeout(
        const Duration(seconds: 60),
        onTimeout: () => ProcessResult(-1, -1, '', 'Script timed out after 60 seconds'),
      );

      final stdout = (result.stdout ?? '').toString().trim();
      final stderr = (result.stderr ?? '').toString().trim();
      final exitCode = result.exitCode;

      final buf = StringBuffer();
      if (exitCode == 0) {
        buf.writeln('Script completed successfully (exit code: 0)');
      } else {
        buf.writeln('Script failed (exit code: $exitCode)');
      }
      if (stdout.isNotEmpty) {
        buf.writeln();
        buf.writeln('--- stdout ---');
        // Truncate if too long
        if (stdout.length > 8000) {
          buf.writeln(stdout.substring(0, 8000));
          buf.writeln('... (truncated, ${stdout.length} chars total)');
        } else {
          buf.writeln(stdout);
        }
      }
      if (stderr.isNotEmpty) {
        buf.writeln();
        buf.writeln('--- stderr ---');
        if (stderr.length > 4000) {
          buf.writeln(stderr.substring(0, 4000));
          buf.writeln('... (truncated)');
        } else {
          buf.writeln(stderr);
        }
      }
      return buf.toString();
    } catch (e) {
      return 'Error executing script: $e';
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // List resource files helper
  // ═══════════════════════════════════════════════════════════════════════════

  /// List all resource files in a skill directory for the LLM.
  static Future<List<String>> listResourceFiles(String skillDirectoryPath) async {
    final files = <String>[];
    try {
      final dir = Directory(skillDirectoryPath);
      if (!await dir.exists()) return files;

      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final relative = p.relative(entity.path, from: skillDirectoryPath);
          // Skip SKILL.md itself
          if (relative == 'SKILL.md') continue;
          files.add(relative);
        }
      }
    } catch (_) {}
    return files;
  }
}
