import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/models/agent_skill.dart';
import '../../../shared/widgets/ios_switch.dart';
import 'skill_detail_page.dart';
import 'skill_directories_page.dart';
import 'skill_editor_page.dart';
import 'skill_import_page.dart';

/// Mobile page for browsing and toggling Agent Skills.
class SkillsListPage extends StatefulWidget {
  const SkillsListPage({super.key});

  @override
  State<SkillsListPage> createState() => _SkillsListPageState();
}

class _SkillsListPageState extends State<SkillsListPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AgentSkillProvider>().initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final provider = context.watch<AgentSkillProvider>();
    final skills = provider.skills;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentSkillsTitle),
        actions: [
          IconButton(
            icon: const Icon(Lucide.FilePlus, size: 20),
            tooltip: l10n.agentSkillEditorCreateTitle,
            onPressed: () async {
              final result = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => const SkillEditorPage(),
                ),
              );
              if (result != null && mounted) {
                provider.refresh();
              }
            },
          ),
          IconButton(
            icon: const Icon(Lucide.FolderInput, size: 20),
            tooltip: l10n.agentSkillImportTitle,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SkillImportPage(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Lucide.Settings2, size: 20),
            tooltip: l10n.agentSkillsManageDirectories,
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SkillDirectoriesPage(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Lucide.RefreshCw, size: 20),
            tooltip: l10n.agentSkillsRefresh,
            onPressed: () => provider.refresh(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: skills.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Lucide.Sparkles,
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
              itemCount: skills.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final skill = skills[index];
                return _SkillCard(skill: skill);
              },
            ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.skill});
  final AgentSkillMeta skill;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<AgentSkillProvider>();
    final isEnabled = provider.isEnabled(skill.name);

    final bg = isEnabled
        ? (isDark ? Colors.white10 : cs.surface)
        : (isDark
            ? Colors.white.withOpacity(0.04)
            : cs.surfaceContainerHighest.withOpacity(0.5));
    final borderColor = isEnabled
        ? cs.outlineVariant.withOpacity(0.25)
        : cs.outlineVariant.withOpacity(0.12);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SkillDetailPage(skill: skill),
          ),
        );
      },
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
                child: Icon(Lucide.Sparkles, size: 20, color: cs.primary),
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
                onChanged: (v) async {
                  await context
                      .read<AgentSkillProvider>()
                      .toggleSkill(skill.name, enabled: v);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
