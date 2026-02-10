import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/agent_skill_provider.dart';
import '../../../core/services/agent_skills/skill_import_export.dart';

/// Page for importing Agent Skills from ZIP files or GitHub URLs.
class SkillImportPage extends StatefulWidget {
  const SkillImportPage({super.key});

  @override
  State<SkillImportPage> createState() => _SkillImportPageState();
}

class _SkillImportPageState extends State<SkillImportPage> {
  final _urlController = TextEditingController();
  bool _importing = false;
  String? _statusMessage;
  bool _isError = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _importFromZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: 'Select Skill ZIP',
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    setState(() {
      _importing = true;
      _statusMessage = null;
    });

    final zipResult = await AgentSkillImportExport.importFromZip(path);

    if (!mounted) return;

    if (zipResult.error != null) {
      setState(() {
        _importing = false;
        _statusMessage = zipResult.error;
        _isError = true;
      });
    } else {
      await context.read<AgentSkillProvider>().refresh();
      setState(() {
        _importing = false;
        _statusMessage = 'Skill imported successfully';
        _isError = false;
      });
    }
  }

  Future<void> _importFromGitHub() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _statusMessage = 'Please enter a GitHub URL';
        _isError = true;
      });
      return;
    }

    setState(() {
      _importing = true;
      _statusMessage = null;
    });

    final ghResult = await AgentSkillImportExport.importFromGitHub(url);

    if (!mounted) return;

    if (ghResult.error != null) {
      setState(() {
        _importing = false;
        _statusMessage = ghResult.error;
        _isError = true;
      });
    } else {
      await context.read<AgentSkillProvider>().refresh();
      setState(() {
        _importing = false;
        _statusMessage = 'Skill imported successfully';
        _isError = false;
        _urlController.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.agentSkillImportTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          // ── Import from ZIP ──
          _SectionCard(
            isDark: isDark,
            cs: cs,
            icon: Lucide.FolderInput,
            title: l10n.agentSkillImportFromZip,
            subtitle: l10n.agentSkillImportFromZipDesc,
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Lucide.Upload, size: 18),
                label: Text(l10n.agentSkillImportSelectFile),
                onPressed: _importing ? null : _importFromZip,
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ── Import from GitHub ──
          _SectionCard(
            isDark: isDark,
            cs: cs,
            icon: Lucide.Github,
            title: l10n.agentSkillImportFromGitHub,
            subtitle: l10n.agentSkillImportFromGitHubDesc,
            child: Column(
              children: [
                TextField(
                  controller: _urlController,
                  enabled: !_importing,
                  decoration: InputDecoration(
                    hintText: 'https://github.com/owner/repo/tree/main/skills/my-skill',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => _importFromGitHub(),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Lucide.Download, size: 18),
                    label: Text(l10n.agentSkillImportFromGitHubAction),
                    onPressed: _importing ? null : _importFromGitHub,
                  ),
                ),
              ],
            ),
          ),

          // ── Status / Loading ──
          if (_importing) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator.adaptive()),
          ],

          if (_statusMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isError
                    ? Colors.red.withOpacity(0.1)
                    : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isError
                      ? Colors.red.withOpacity(0.3)
                      : Colors.green.withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isError ? Lucide.CircleX : Lucide.CheckCircle,
                    size: 18,
                    color: _isError ? Colors.red : Colors.green,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(
                        color: _isError ? Colors.red : Colors.green,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.isDark,
    required this.cs,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final bool isDark;
  final ColorScheme cs;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : cs.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(0.25),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: cs.primary),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}
