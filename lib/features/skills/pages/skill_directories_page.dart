import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/services/agent_skills/skill_store.dart';

/// Mobile page for managing Agent Skills search directories.
class SkillDirectoriesPage extends StatefulWidget {
  const SkillDirectoriesPage({super.key});

  @override
  State<SkillDirectoriesPage> createState() => _SkillDirectoriesPageState();
}

class _SkillDirectoriesPageState extends State<SkillDirectoriesPage> {
  List<String> _dirs = const <String>[];
  Set<String> _protectedDirs = const <String>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dirs = await AgentSkillStore.getSearchDirectories();
    final wellKnown = (await AgentSkillStore.getWellKnownDirectories()).toSet();
    if (!mounted) return;
    setState(() {
      _dirs = dirs;
      _protectedDirs = wellKnown;
      _loading = false;
    });
  }

  Future<void> _addDirectory() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    final added =
        await context.read<AgentSkillProvider>().addSearchDirectory(result);
    if (added) await _load();
  }

  Future<void> _removeDirectory(String path) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.agentSkillsRemoveDirectory),
        content: Text(l10n.agentSkillsRemoveDirectoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.agentSkillsRemoveDirectory),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await context.read<AgentSkillProvider>().removeSearchDirectory(path);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentSkillsDirectories),
        actions: [
          IconButton(
            icon: Icon(Lucide.Plus, size: 20),
            tooltip: l10n.agentSkillsAddDirectory,
            onPressed: _addDirectory,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator.adaptive())
          : _dirs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Lucide.FolderOpen,
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
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _dirs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final dir = _dirs[index];
                    final isDefault =
                        _protectedDirs.contains(dir);
                    return Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withOpacity(0.06)
                            : cs.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: cs.outlineVariant.withOpacity(0.15),
                          width: 0.5,
                        ),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                        leading: Icon(
                          Lucide.Folder,
                          color: cs.primary,
                          size: 22,
                        ),
                        title: Text(
                          dir,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: isDefault
                            ? Text(
                                l10n.agentSkillsDefaultDir,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.primary,
                                ),
                              )
                            : null,
                        trailing: isDefault
                            ? null
                            : IconButton(
                                icon: Icon(
                                  Lucide.Trash2,
                                  size: 18,
                                  color: cs.error,
                                ),
                                onPressed: () => _removeDirectory(dir),
                              ),
                      ),
                    );
                  },
                ),
    );
  }
}
