import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/models/agent_skill.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/services/agent_skills/skill_store.dart';
import '../../../core/services/agent_skills/skill_import_export.dart';
import 'skill_editor_page.dart';

/// Displays full detail for a single Agent Skill, including metadata and
/// rendered instructions.
class SkillDetailPage extends StatefulWidget {
  const SkillDetailPage({super.key, required this.skill});
  final AgentSkillMeta skill;

  @override
  State<SkillDetailPage> createState() => _SkillDetailPageState();
}

class _SkillDetailPageState extends State<SkillDetailPage> {
  AgentSkill? _full;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFull();
  }

  Future<void> _loadFull() async {
    final full = await AgentSkillStore.loadFull(widget.skill.directoryPath);
    if (!mounted) return;
    setState(() {
      _full = full;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<AgentSkillProvider>();
    final isEnabled = provider.isEnabled(widget.skill.name);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentSkillsDetailTitle),
        actions: [
          IconButton(
            icon: const Icon(Lucide.Pencil, size: 20),
            tooltip: l10n.agentSkillEditorEditTitle,
            onPressed: () async {
              final result = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => SkillEditorPage(
                    existingSkillPath: widget.skill.directoryPath,
                  ),
                ),
              );
              if (result != null && mounted) _loadFull();
            },
          ),
          IconButton(
            icon: const Icon(Lucide.FolderOutput, size: 20),
            tooltip: l10n.agentSkillExportTitle,
            onPressed: () async {
              final result = await FilePicker.platform.saveFile(
                dialogTitle: 'Export Skill as ZIP',
                fileName: '${widget.skill.name}.zip',
                type: FileType.custom,
                allowedExtensions: ['zip'],
              );
              if (result == null || !mounted) return;
              final (:path, :error) = await AgentSkillImportExport.exportToZip(
                widget.skill.directoryPath,
                result,
              );
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(error ?? 'Skill exported successfully'),
                ),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // ── Header ──
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white10
                            : const Color(0xFFF2F3F5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Lucide.Sparkles, size: 24, color: cs.primary),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.skill.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isEnabled
                                ? l10n.agentSkillsEnabled
                                : l10n.agentSkillsDisabled,
                            style: TextStyle(
                              fontSize: 13,
                              color: isEnabled
                                  ? cs.primary
                                  : cs.onSurface.withOpacity(0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Description ──
                _SectionCard(
                  children: [
                    Text(
                      widget.skill.description,
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurface.withOpacity(0.85),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // ── Metadata fields ──
                _SectionCard(
                  children: [
                    if (widget.skill.license != null)
                      _MetaRow(
                        label: l10n.agentSkillsLicense,
                        value: widget.skill.license!,
                      ),
                    if (widget.skill.compatibility != null) ...[
                      if (widget.skill.license != null)
                        Divider(
                          height: 1,
                          color: cs.outlineVariant.withOpacity(0.15),
                        ),
                      _MetaRow(
                        label: l10n.agentSkillsCompatibility,
                        value: widget.skill.compatibility!,
                      ),
                    ],
                    if (widget.skill.allowedTools.isNotEmpty) ...[
                      Divider(
                        height: 1,
                        color: cs.outlineVariant.withOpacity(0.15),
                      ),
                      _MetaRow(
                        label: l10n.agentSkillsAllowedTools,
                        value: widget.skill.allowedTools.join(', '),
                      ),
                    ],
                    Divider(
                      height: 1,
                      color: cs.outlineVariant.withOpacity(0.15),
                    ),
                    _MetaRow(
                      label: l10n.agentSkillsPath,
                      value: widget.skill.directoryPath,
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Instructions ──
                Text(
                  l10n.agentSkillsInstructions,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.7),
                  ),
                ),
                const SizedBox(height: 8),
                _SectionCard(
                  children: [
                    Text(
                      (_full?.instructions ?? '').trim().isEmpty
                          ? l10n.agentSkillsNoInstructions
                          : _full!.instructions,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withOpacity(0.85),
                        height: 1.6,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.06) : cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(0.15),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withOpacity(0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
