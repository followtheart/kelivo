import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/models/agent_skill.dart';
import '../../core/providers/agent_skill_provider.dart';
import '../../core/services/agent_skills/skill_store.dart';
import '../../core/services/agent_skills/skill_import_export.dart';
import '../../shared/widgets/ios_switch.dart';
import '../../features/skills/pages/skill_editor_page.dart';

/// Desktop pane for Agent Skills in the settings page.
///
/// Follows the same layout pattern as [DesktopInstructionInjectionPane] and
/// [DesktopWorldBookPane]: Container > Padding > ConstrainedBox > CustomScrollView.
class DesktopAgentSkillsPane extends StatefulWidget {
  const DesktopAgentSkillsPane({super.key});

  @override
  State<DesktopAgentSkillsPane> createState() => _DesktopAgentSkillsPaneState();
}

class _DesktopAgentSkillsPaneState extends State<DesktopAgentSkillsPane> {
  bool _showDirectories = false;
  List<String> _dirs = const <String>[];
  Set<String> _wellKnownDirs = const <String>{};
  AgentSkill? _selectedSkill;
  bool _loadingDetail = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AgentSkillProvider>().initialize();
      _loadDirs();
    });
  }

  Future<void> _loadDirs() async {
    final dirs = await AgentSkillStore.getSearchDirectories();
    final wellKnown = (await AgentSkillStore.getWellKnownDirectories()).toSet();
    if (!mounted) return;
    setState(() {
      _dirs = dirs;
      _wellKnownDirs = wellKnown;
    });
  }

  Future<void> _addDirectory() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null || result.isEmpty || !mounted) return;
    final added =
        await context.read<AgentSkillProvider>().addSearchDirectory(result);
    if (added) await _loadDirs();
  }

  Future<void> _removeDirectory(String path) async {
    if (!mounted) return;
    await context.read<AgentSkillProvider>().removeSearchDirectory(path);
    await _loadDirs();
  }

  Future<void> _selectSkill(AgentSkillMeta skill) async {
    setState(() => _loadingDetail = true);
    final full = await AgentSkillStore.loadFull(skill.directoryPath);
    if (!mounted) return;
    setState(() {
      _selectedSkill = full;
      _loadingDetail = false;
    });
  }

  Future<void> _importSkillZip(AgentSkillProvider provider) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: 'Select Skill ZIP',
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.single.path;
    if (path == null) return;

    final importResult = await AgentSkillImportExport.importFromZip(path);

    if (!mounted) return;

    if (importResult.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import error: ${importResult.error}')),
      );
    } else {
      await provider.refresh();
      await _loadDirs();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Skill imported successfully')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final provider = context.watch<AgentSkillProvider>();
    final skills = provider.skills;

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: CustomScrollView(
            slivers: [
              // ── Title bar ──
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l10n.agentSkillsTitle,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: cs.onSurface.withOpacity(0.9),
                            ),
                          ),
                        ),
                      ),
                      _SmallIconBtn(
                        icon: lucide.Lucide.FilePlus,
                        onTap: () async {
                          final result = await Navigator.of(context).push<String>(
                            MaterialPageRoute(
                              builder: (_) => const SkillEditorPage(),
                            ),
                          );
                          if (result != null && mounted) {
                            await provider.refresh();
                            await _loadDirs();
                          }
                        },
                        tooltip: l10n.agentSkillEditorCreateTitle,
                      ),
                      const SizedBox(width: 6),
                      _SmallIconBtn(
                        icon: lucide.Lucide.FolderInput,
                        onTap: () => _importSkillZip(provider),
                        tooltip: l10n.agentSkillImportTitle,
                      ),
                      const SizedBox(width: 6),
                      _SmallIconBtn(
                        icon: lucide.Lucide.Settings2,
                        onTap: () => setState(
                          () => _showDirectories = !_showDirectories,
                        ),
                        tooltip: l10n.agentSkillsManageDirectories,
                      ),
                      const SizedBox(width: 6),
                      _SmallIconBtn(
                        icon: lucide.Lucide.RefreshCw,
                        onTap: () async {
                          await provider.refresh();
                          await _loadDirs();
                          setState(() => _selectedSkill = null);
                        },
                        tooltip: l10n.agentSkillsRefresh,
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // ── Directory panel (collapsible) ──
              if (_showDirectories) ...[
                SliverToBoxAdapter(
                  child: _DirectoriesPanel(
                    dirs: _dirs,
                    protectedDirs: _wellKnownDirs,
                    onAdd: _addDirectory,
                    onRemove: _removeDirectory,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ],

              // ── Empty state ──
              if (skills.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            lucide.Lucide.Sparkles,
                            size: 56,
                            color: cs.onSurface.withOpacity(0.28),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.agentSkillsEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: cs.onSurface.withOpacity(0.65),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...[
                // ── Skill list ──
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final skill = skills[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SkillRow(
                          skill: skill,
                          isEnabled: provider.isEnabled(skill.name),
                          isSelected: _selectedSkill?.name == skill.name,
                          onTap: () => _selectSkill(skill),
                          onToggle: (v) => provider.toggleSkill(
                            skill.name,
                            enabled: v,
                          ),
                        ),
                      );
                    },
                    childCount: skills.length,
                  ),
                ),

                // ── Detail panel ──
                if (_loadingDetail)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                    ),
                  )
                else if (_selectedSkill != null) ...[
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
                  SliverToBoxAdapter(
                    child: _SkillDetailPanel(
                      skill: _selectedSkill!,
                      onRefresh: () async {
                        await provider.refresh();
                        await _loadDirs();
                        // Reload the selected skill
                        if (_selectedSkill != null) {
                          final refreshed = await AgentSkillStore.loadFull(
                            _selectedSkill!.directoryPath,
                          );
                          if (mounted) {
                            setState(() => _selectedSkill = refreshed);
                          }
                        }
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Skill row card ─────────────────────────────────────────────────────────

class _SkillRow extends StatelessWidget {
  const _SkillRow({
    required this.skill,
    required this.isEnabled,
    required this.isSelected,
    required this.onTap,
    required this.onToggle,
  });
  final AgentSkillMeta skill;
  final bool isEnabled;
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = isSelected
        ? cs.primary.withOpacity(isDark ? 0.12 : 0.10)
        : (isDark ? Colors.white10 : cs.surface);
    final borderColor = isSelected
        ? cs.primary.withOpacity(0.45)
        : cs.outlineVariant.withOpacity(0.25);

    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 0.6),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    lucide.Lucide.Sparkles,
                    size: 20,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        skill.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        skill.description,
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withOpacity(0.65),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (skill.license != null) ...[
                        const SizedBox(height: 6),
                        _Tag(text: skill.license!),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IosSwitch(
                  value: isEnabled,
                  onChanged: onToggle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Skill detail panel ─────────────────────────────────────────────────────

class _SkillDetailPanel extends StatelessWidget {
  const _SkillDetailPanel({required this.skill, this.onRefresh});
  final AgentSkill skill;
  final VoidCallback? onRefresh;

  Future<void> _exportSkill(BuildContext context) async {
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Skill as ZIP',
      fileName: '${skill.name}.zip',
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (result == null) return;

    final (:path, :error) = await AgentSkillImportExport.exportToZip(
      skill.directoryPath,
      result,
    );

    if (!context.mounted) return;

    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export error: $error')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Skill exported successfully')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.04) : cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(0.15),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + Actions
          Row(
            children: [
              Expanded(
                child: Text(
                  skill.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              _SmallIconBtn(
                icon: lucide.Lucide.Pencil,
                onTap: () async {
                  final result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          SkillEditorPage(existingSkillPath: skill.directoryPath),
                    ),
                  );
                  if (result != null) onRefresh?.call();
                },
                tooltip: l10n.agentSkillEditorEditTitle,
              ),
              const SizedBox(width: 4),
              _SmallIconBtn(
                icon: lucide.Lucide.FolderOutput,
                onTap: () => _exportSkill(context),
                tooltip: l10n.agentSkillExportTitle,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            skill.description,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.8),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),

          // Metadata rows
          if (skill.license != null)
            _DetailMetaRow(label: l10n.agentSkillsLicense, value: skill.license!),
          if (skill.compatibility != null)
            _DetailMetaRow(
              label: l10n.agentSkillsCompatibility,
              value: skill.compatibility!,
            ),
          if (skill.allowedTools.isNotEmpty)
            _DetailMetaRow(
              label: l10n.agentSkillsAllowedTools,
              value: skill.allowedTools.join(', '),
            ),
          _DetailMetaRow(label: l10n.agentSkillsPath, value: skill.directoryPath),

          const SizedBox(height: 12),
          Divider(height: 1, color: cs.outlineVariant.withOpacity(0.15)),
          const SizedBox(height: 12),

          // Instructions
          Text(
            l10n.agentSkillsInstructions,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.03)
                  : cs.surfaceContainerHighest.withOpacity(0.4),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              skill.instructions.trim().isEmpty
                  ? l10n.agentSkillsNoInstructions
                  : skill.instructions,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.85),
                height: 1.6,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailMetaRow extends StatelessWidget {
  const _DetailMetaRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withOpacity(0.55),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withOpacity(0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Directories panel ──────────────────────────────────────────────────────

class _DirectoriesPanel extends StatelessWidget {
  const _DirectoriesPanel({
    required this.dirs,
    required this.protectedDirs,
    required this.onAdd,
    required this.onRemove,
  });
  final List<String> dirs;
  final Set<String> protectedDirs;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.04) : cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(0.15),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.agentSkillsDirectories,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withOpacity(0.8),
                  ),
                ),
              ),
              _SmallIconBtn(
                icon: lucide.Lucide.Plus,
                onTap: onAdd,
                tooltip: l10n.agentSkillsAddDirectory,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (dirs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                l10n.agentSkillsEmpty,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withOpacity(0.5),
                ),
              ),
            )
          else
            for (final dir in dirs) ...[
              Row(
                children: [
                  Icon(lucide.Lucide.Folder, size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      dir,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withOpacity(0.8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (protectedDirs.contains(dir))
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        l10n.agentSkillsDefaultDir,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    _SmallIconBtn(
                      icon: lucide.Lucide.Trash2,
                      onTap: () => onRemove(dir),
                      tooltip: l10n.agentSkillsRemoveDirectory,
                      iconColor: cs.error,
                    ),
                ],
              ),
              const SizedBox(height: 4),
            ],
        ],
      ),
    );
  }
}

// ─── Shared widgets ─────────────────────────────────────────────────────────

class _Tag extends StatelessWidget {
  const _Tag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: cs.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SmallIconBtn extends StatelessWidget {
  const _SmallIconBtn({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.iconColor,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = IconButton(
      icon: Icon(icon, size: 18, color: iconColor ?? cs.onSurface.withOpacity(0.7)),
      onPressed: onTap,
      splashRadius: 16,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
    return tooltip != null ? Tooltip(message: tooltip!, child: w) : w;
  }
}
