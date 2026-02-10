import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/services/agent_skills/skill_store.dart';

/// In-app wizard for creating or editing a SKILL.md file.
///
/// Provides a form-based editor for the YAML frontmatter and a text area
/// for the skill instructions (Markdown body).
class SkillEditorPage extends StatefulWidget {
  const SkillEditorPage({super.key, this.existingSkillPath});

  /// If provided, edit an existing skill. Otherwise create a new one.
  final String? existingSkillPath;

  @override
  State<SkillEditorPage> createState() => _SkillEditorPageState();
}

class _SkillEditorPageState extends State<SkillEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _licenseController = TextEditingController();
  final _compatibilityController = TextEditingController();
  final _allowedToolsController = TextEditingController();
  final _instructionsController = TextEditingController();

  bool _saving = false;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.existingSkillPath != null;
    if (_isEditing) {
      _loadExisting();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _licenseController.dispose();
    _compatibilityController.dispose();
    _allowedToolsController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    final skillMdFile = File(p.join(widget.existingSkillPath!, 'SKILL.md'));
    if (!await skillMdFile.exists()) return;
    final content = await skillMdFile.readAsString();

    // Parse frontmatter and body
    if (content.startsWith('---')) {
      final secondDash = content.indexOf('---', 3);
      if (secondDash != -1) {
        final frontmatter = content.substring(3, secondDash).trim();
        final body = content.substring(secondDash + 3).trim();

        // Parse YAML-like frontmatter line by line
        for (final line in frontmatter.split('\n')) {
          final idx = line.indexOf(':');
          if (idx == -1) continue;
          final key = line.substring(0, idx).trim();
          final value = line.substring(idx + 1).trim();
          switch (key) {
            case 'name':
              _nameController.text = value;
              break;
            case 'description':
              _descriptionController.text = _unquote(value);
              break;
            case 'license':
              _licenseController.text = value;
              break;
            case 'compatibility':
              _compatibilityController.text = value;
              break;
            case 'allowed_tools':
              // Could be inline list [a,b] or multi-line
              if (value.startsWith('[') && value.endsWith(']')) {
                _allowedToolsController.text =
                    value.substring(1, value.length - 1);
              }
              break;
          }
        }

        _instructionsController.text = body;
      }
    }
    if (mounted) setState(() {});
  }

  String _unquote(String s) {
    if ((s.startsWith('"') && s.endsWith('"')) ||
        (s.startsWith("'") && s.endsWith("'"))) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final name = _nameController.text.trim();
      final description = _descriptionController.text.trim();
      final license = _licenseController.text.trim();
      final compatibility = _compatibilityController.text.trim();
      final allowedToolsRaw = _allowedToolsController.text.trim();
      final instructions = _instructionsController.text.trim();

      // Build SKILL.md content
      final buf = StringBuffer();
      buf.writeln('---');
      buf.writeln('name: $name');
      buf.writeln('description: "${_yamlEscape(description)}"');
      if (license.isNotEmpty) buf.writeln('license: $license');
      if (compatibility.isNotEmpty) {
        buf.writeln('compatibility: $compatibility');
      }
      if (allowedToolsRaw.isNotEmpty) {
        final tools = allowedToolsRaw
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
        buf.writeln('allowed_tools: [${tools.join(", ")}]');
      }
      buf.writeln('---');
      buf.writeln();
      buf.writeln(instructions);

      // Determine target directory
      String targetDir;
      if (_isEditing) {
        targetDir = widget.existingSkillPath!;
      } else {
        final defaultDir = await AgentSkillStore.getDefaultSkillsDirectory();
        targetDir = p.join(defaultDir, name);
      }

      // Create directory if needed
      final dir = Directory(targetDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      // Write SKILL.md
      final skillMdFile = File(p.join(targetDir, 'SKILL.md'));
      await skillMdFile.writeAsString(buf.toString());

      // Refresh provider
      if (mounted) {
        await context.read<AgentSkillProvider>().refresh();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEditing
                ? 'Skill "$name" updated'
                : 'Skill "$name" created'),
          ),
        );
        Navigator.of(context).pop(targetDir);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _yamlEscape(String s) {
    return s.replaceAll('"', '\\"');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing
            ? l10n.agentSkillEditorEditTitle
            : l10n.agentSkillEditorCreateTitle),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Lucide.Save, size: 20),
              tooltip: l10n.agentSkillEditorSave,
              onPressed: _save,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // Section: Metadata
            _SectionHeader(
              icon: Lucide.FileCode,
              title: l10n.agentSkillEditorMetadata,
            ),
            const SizedBox(height: 12),

            // Name
            TextFormField(
              controller: _nameController,
              enabled: !_isEditing,
              decoration: InputDecoration(
                labelText: l10n.agentSkillEditorName,
                hintText: 'my-skill',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return l10n.agentSkillEditorNameRequired;
                final name = v.trim();
                // Validate name format: alphanumeric, hyphens, underscores
                if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name)) {
                  return l10n.agentSkillEditorNameInvalid;
                }
                return null;
              },
            ),
            const SizedBox(height: 12),

            // Description
            TextFormField(
              controller: _descriptionController,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l10n.agentSkillEditorDescription,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return l10n.agentSkillEditorDescriptionRequired;
                return null;
              },
            ),
            const SizedBox(height: 12),

            // License & Compatibility row
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _licenseController,
                    decoration: InputDecoration(
                      labelText: l10n.agentSkillEditorLicense,
                      hintText: 'MIT',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _compatibilityController,
                    decoration: InputDecoration(
                      labelText: l10n.agentSkillEditorCompatibility,
                      hintText: 'claude,gpt',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Allowed tools
            TextFormField(
              controller: _allowedToolsController,
              decoration: InputDecoration(
                labelText: l10n.agentSkillEditorAllowedTools,
                hintText: 'read_file, run_terminal',
                helperText: l10n.agentSkillEditorAllowedToolsHelper,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Section: Instructions
            _SectionHeader(
              icon: Lucide.BookOpenText,
              title: l10n.agentSkillEditorInstructions,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.agentSkillEditorInstructionsHelper,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.55),
              ),
            ),
            const SizedBox(height: 8),

            // Instructions editor
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: isDark
                      ? Colors.white24
                      : cs.outlineVariant.withOpacity(0.4),
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: TextFormField(
                controller: _instructionsController,
                maxLines: null,
                minLines: 12,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.5,
                ),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(12),
                  border: InputBorder.none,
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return l10n.agentSkillEditorInstructionsRequired;
                  return null;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}
