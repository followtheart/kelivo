import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/models/memory.dart';
import '../../../core/providers/memory_provider.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';

/// Standalone memory management page with tab-based navigation (Global + per-assistant),
/// search, category filtering, sort toggle, and CRUD operations.
class MemoryManagementPage extends StatefulWidget {
  /// Optional initial tab index. 0 = Global, 1..N = assistants in order.
  final int initialTabIndex;

  const MemoryManagementPage({super.key, this.initialTabIndex = 0});

  @override
  State<MemoryManagementPage> createState() => _MemoryManagementPageState();
}

class _MemoryManagementPageState extends State<MemoryManagementPage> with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  MemoryCategory? _selectedCategory;
  bool _sortByImportance = false; // false = by date (default), true = by importance

  @override
  void initState() {
    super.initState();
    final assistants = context.read<AssistantProvider>().assistants;
    _tabController = TabController(
      length: assistants.length + 1, // +1 for global tab
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, assistants.length),
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    // Ensure memories are loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MemoryProvider>().initialize();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Returns filtered & sorted memories for the current tab.
  List<Memory> _getFilteredMemories(MemoryProvider mp, AssistantProvider ap) {
    final assistants = ap.assistants;
    final tabIndex = _tabController.index;
    final query = _searchController.text.trim();

    List<Memory> base;
    if (tabIndex == 0) {
      // Global tab — use in-memory filtering to include private memories in UI
      base = mp.memories.where((m) => m.scope == MemoryScope.global).toList();
      if (query.isNotEmpty) {
        final q = query.toLowerCase();
        base = base.where((m) =>
            m.content.toLowerCase().contains(q) ||
            m.concepts.any((c) => c.toLowerCase().contains(q))).toList();
      }
    } else {
      // Assistant tab
      final assistantId = assistants[tabIndex - 1].id;
      base = mp.getForAssistant(assistantId);
      if (query.isNotEmpty) {
        final q = query.toLowerCase();
        base = base.where((m) =>
            m.content.toLowerCase().contains(q) ||
            m.concepts.any((c) => c.toLowerCase().contains(q))).toList();
      }
    }

    // Category filter
    if (_selectedCategory != null) {
      base = base.where((m) => m.category == _selectedCategory).toList();
    }

    // Sort
    if (_sortByImportance) {
      base.sort((a, b) => b.importance.compareTo(a.importance));
    } else {
      base.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }

    return base;
  }

  /// Get the assistantId for the current tab, or null for global.
  String? _currentAssistantId(AssistantProvider ap) {
    final tabIndex = _tabController.index;
    if (tabIndex == 0) return null;
    return ap.assistants[tabIndex - 1].id;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ap = context.watch<AssistantProvider>();
    final mp = context.watch<MemoryProvider>();
    final assistants = ap.assistants;
    final memories = _getFilteredMemories(mp, ap);

    // Rebuild tab controller if assistant count changes
    if (_tabController.length != assistants.length + 1) {
      final oldIndex = _tabController.index;
      _tabController.dispose();
      _tabController = TabController(
        length: assistants.length + 1,
        vsync: this,
        initialIndex: oldIndex.clamp(0, assistants.length),
      );
      _tabController.addListener(() {
        if (!_tabController.indexIsChanging) setState(() {});
      });
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Lucide.ArrowLeft, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          l10n.memoryManagementTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Lucide.Download, size: 20),
            tooltip: l10n.memoryManagementExport,
            onPressed: () => _exportMemories(context, mp),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w400),
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurface.withOpacity(0.6),
          indicatorColor: cs.primary,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: cs.outlineVariant.withOpacity(0.18),
          tabs: [
            Tab(text: l10n.memoryManagementGlobalTab),
            ...assistants.map((a) => Tab(text: a.name.isEmpty ? 'Assistant' : a.name)),
          ],
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10n.memoryManagementSearchHint,
                hintStyle: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.45)),
                prefixIcon: Icon(Lucide.Search, size: 18, color: cs.onSurface.withOpacity(0.5)),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(Lucide.X, size: 16, color: cs.onSurface.withOpacity(0.5)),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      )
                    : null,
                filled: true,
                fillColor: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
                contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.2)),
                  borderRadius: BorderRadius.circular(12),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.2)),
                  borderRadius: BorderRadius.circular(12),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: cs.primary.withOpacity(0.5)),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          // Filter chips + sort toggle
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _FilterChip(
                          label: l10n.memoryManagementFilterAll,
                          selected: _selectedCategory == null,
                          onTap: () => setState(() => _selectedCategory = null),
                        ),
                        ...MemoryCategory.values.map((cat) => Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: _FilterChip(
                                label: _categoryLabel(cat, l10n),
                                selected: _selectedCategory == cat,
                                onTap: () => setState(() {
                                  _selectedCategory = _selectedCategory == cat ? null : cat;
                                }),
                              ),
                            )),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SortToggle(
                  sortByImportance: _sortByImportance,
                  onToggle: () => setState(() => _sortByImportance = !_sortByImportance),
                ),
              ],
            ),
          ),

          // Memory list
          Expanded(
            child: memories.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Lucide.Brain, size: 40, color: cs.onSurface.withOpacity(0.2)),
                        const SizedBox(height: 12),
                        Text(
                          l10n.memoryManagementEmpty,
                          style: TextStyle(
                            fontSize: 14,
                            color: cs.onSurface.withOpacity(0.5),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: memories.length + 1, // +1 for footer count
                    itemBuilder: (context, index) {
                      if (index == memories.length) {
                        // Footer count
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: Text(
                              l10n.memoryManagementCount(memories.length),
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurface.withOpacity(0.4),
                              ),
                            ),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _MemoryCard(
                          memory: memories[index],
                          onEdit: () => _showAddEditDialog(context, memory: memories[index]),
                          onDelete: () => _confirmDelete(context, memories[index]),
                          onTogglePrivate: () => _togglePrivate(context, memories[index]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditDialog(context),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        icon: const Icon(Lucide.Plus, size: 18),
        label: Text(l10n.memoryManagementAddButton),
      ),
      bottomNavigationBar: _buildBottomBar(context, mp, ap),
    );
  }

  Widget? _buildBottomBar(BuildContext context, MemoryProvider mp, AssistantProvider ap) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final assistantId = _currentAssistantId(ap);
    final hasMemories = assistantId == null
        ? mp.memories.any((m) => m.scope == MemoryScope.global)
        : mp.getForAssistant(assistantId).isNotEmpty;

    if (!hasMemories) return null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: TextButton.icon(
          onPressed: () => _confirmClearAll(context, assistantId),
          icon: Icon(Lucide.AlertTriangle, size: 16, color: cs.error),
          label: Text(
            l10n.memoryManagementClearAll,
            style: TextStyle(color: cs.error, fontSize: 13),
          ),
          style: TextButton.styleFrom(
            backgroundColor: isDark
                ? cs.error.withOpacity(0.08)
                : cs.error.withOpacity(0.05),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  // --- Dialogs ---

  Future<void> _showAddEditDialog(BuildContext context, {Memory? memory}) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController(text: memory?.content ?? '');
    final ap = context.read<AssistantProvider>();
    final assistantId = _currentAssistantId(ap);

    // Determine category & importance for new memories
    var editCategory = memory?.category ?? MemoryCategory.custom;
    var editImportance = memory?.importance ?? 3;

    final platform = Theme.of(context).platform;
    final isDesktop = platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.windows;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          return Dialog(
            backgroundColor: cs.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            insetPadding: EdgeInsets.symmetric(
              horizontal: isDesktop ? 24 : 16,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isDesktop ? 560 : 400),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Title bar
                    SizedBox(
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(Lucide.Brain, size: 18, color: cs.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                memory != null
                                    ? l10n.memoryManagementEditTitle
                                    : l10n.memoryManagementAddTitle,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700),
                              ),
                            ),
                            IconButton(
                              tooltip: MaterialLocalizations.of(ctx).closeButtonTooltip,
                              icon: const Icon(Lucide.X, size: 18),
                              color: cs.onSurface,
                              onPressed: () => Navigator.of(ctx).maybePop(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Content
                          TextField(
                            controller: controller,
                            minLines: 3,
                            maxLines: 8,
                            decoration: InputDecoration(
                              hintText: l10n.memoryManagementContentHint,
                              filled: true,
                              fillColor: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
                              border: OutlineInputBorder(
                                borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.2)),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: cs.primary.withOpacity(0.5)),
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            autofocus: true,
                          ),
                          const SizedBox(height: 14),

                          // Category selector
                          Text(l10n.memoryManagementCategoryLabel,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withOpacity(0.7))),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: MemoryCategory.values.map((cat) {
                              final selected = editCategory == cat;
                              return ChoiceChip(
                                label: Text(_categoryLabel(cat, l10n),
                                    style: TextStyle(fontSize: 12)),
                                avatar: Icon(_categoryIcon(cat), size: 14),
                                selected: selected,
                                selectedColor: cs.primary.withOpacity(0.15),
                                backgroundColor: isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                                side: BorderSide(
                                  color: selected
                                      ? cs.primary.withOpacity(0.4)
                                      : cs.outlineVariant.withOpacity(0.2),
                                ),
                                onSelected: (_) {
                                  setDialogState(() => editCategory = cat);
                                },
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 14),

                          // Importance slider
                          Text(l10n.memoryManagementImportanceLabel,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withOpacity(0.7))),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              ...List.generate(5, (i) {
                                final starIndex = i + 1;
                                return GestureDetector(
                                  onTap: () {
                                    setDialogState(() => editImportance = starIndex);
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 2),
                                    child: Icon(
                                      Lucide.Star,
                                      size: 22,
                                      color: starIndex <= editImportance
                                          ? Colors.amber
                                          : cs.onSurface.withOpacity(0.2),
                                    ),
                                  ),
                                );
                              }),
                              const SizedBox(width: 8),
                              Text('$editImportance/5',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withOpacity(0.5))),
                            ],
                          ),
                          const SizedBox(height: 18),

                          // Action buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: Text(l10n.memoryManagementCancel),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () async {
                                  final text = controller.text.trim();
                                  if (text.isEmpty) return;
                                  final mp = context.read<MemoryProvider>();
                                  if (memory != null) {
                                    await mp.update(
                                      id: memory.id,
                                      content: text,
                                      category: editCategory,
                                      importance: editImportance,
                                    );
                                  } else {
                                    // Determine scope based on current tab
                                    final scope = assistantId == null
                                        ? MemoryScope.global
                                        : MemoryScope.assistant;
                                    await mp.add(
                                      assistantId: assistantId ?? '',
                                      content: text,
                                      category: editCategory,
                                      importance: editImportance,
                                      scope: scope,
                                      source: MemorySource.userManual,
                                    );
                                  }
                                  if (context.mounted) Navigator.of(ctx).pop();
                                },
                                child: Text(l10n.memoryManagementSave),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        });
      },
    );
  }

  Future<void> _confirmDelete(BuildContext context, Memory memory) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoryManagementDeleteTitle, style: const TextStyle(fontSize: 16)),
        content: Text(
          memory.content.length > 100
              ? '${memory.content.substring(0, 100)}...'
              : memory.content,
          style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.memoryManagementCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.memoryManagementDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context.read<MemoryProvider>().delete(id: memory.id);
    }
  }

  Future<void> _confirmClearAll(BuildContext context, String? assistantId) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoryManagementClearAllTitle, style: const TextStyle(fontSize: 16)),
        content: Text(
          l10n.memoryManagementClearAllMessage,
          style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.7)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.memoryManagementCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.memoryManagementDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      final mp = context.read<MemoryProvider>();
      List<Memory> toDelete;
      if (assistantId == null) {
        toDelete = mp.memories.where((m) => m.scope == MemoryScope.global).toList();
      } else {
        toDelete = mp.getForAssistant(assistantId);
      }
      for (final m in toDelete) {
        await mp.delete(id: m.id);
      }
    }
  }

  /// Toggle the isPrivate flag on a memory.
  Future<void> _togglePrivate(BuildContext context, Memory memory) async {
    final mp = context.read<MemoryProvider>();
    await mp.setPrivate(id: memory.id, isPrivate: !memory.isPrivate);
  }

  /// Export all memories as a JSON file and share/save it.
  Future<void> _exportMemories(BuildContext context, MemoryProvider mp) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final data = mp.exportAll();
      if (data.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.memoryManagementEmpty)),
          );
        }
        return;
      }
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      final dir = await getTemporaryDirectory();
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final file = File('${dir.path}/kelivo_memories_$timestamp.json');
      await file.writeAsString(jsonStr, flush: true);

      // Use share_plus to let the user save/share the file
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: l10n.memoryManagementExport,
        ),
      );
    } catch (e) {
      debugPrint('Export memories failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  // --- Helpers ---

  String _categoryLabel(MemoryCategory cat, AppLocalizations l10n) {
    switch (cat) {
      case MemoryCategory.userProfile:
        return l10n.memoryManagementCatUserProfile;
      case MemoryCategory.preference:
        return l10n.memoryManagementCatPreference;
      case MemoryCategory.fact:
        return l10n.memoryManagementCatFact;
      case MemoryCategory.task:
        return l10n.memoryManagementCatTask;
      case MemoryCategory.decision:
        return l10n.memoryManagementCatDecision;
      case MemoryCategory.learning:
        return l10n.memoryManagementCatLearning;
      case MemoryCategory.custom:
        return l10n.memoryManagementCatCustom;
    }
  }

  IconData _categoryIcon(MemoryCategory cat) {
    switch (cat) {
      case MemoryCategory.userProfile:
        return Lucide.CircleUser;
      case MemoryCategory.preference:
        return Lucide.SlidersHorizontal;
      case MemoryCategory.fact:
        return Lucide.Lightbulb;
      case MemoryCategory.task:
        return Lucide.CircleCheck;
      case MemoryCategory.decision:
        return Lucide.Milestone;
      case MemoryCategory.learning:
        return Lucide.GraduationCap;
      case MemoryCategory.custom:
        return Lucide.Tag;
    }
  }
}

// ───────────────────────────────────────────────────────────────────────
// Local helper widgets (private to this file, following project convention)
// ───────────────────────────────────────────────────────────────────────

/// A single memory card showing importance stars, category, content, concepts, source, date.
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.memory,
    required this.onEdit,
    required this.onDelete,
    required this.onTogglePrivate,
  });

  final Memory memory;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTogglePrivate;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;
    final dateFmt = DateFormat.yMMMd();

    return Opacity(
      opacity: memory.isPrivate ? 0.55 : 1.0,
      child: Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: memory.isPrivate
              ? cs.outlineVariant.withOpacity(isDark ? 0.15 : 0.12)
              : cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06),
          width: 0.6,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: stars + category + expiry badge
            Row(
              children: [
                // Importance stars
                ...List.generate(5, (i) => Icon(
                      Lucide.Star,
                      size: 13,
                      color: i < memory.importance
                          ? Colors.amber
                          : cs.onSurface.withOpacity(0.15),
                    )),
                const SizedBox(width: 8),
                // Category chip
                _categoryChip(context, memory.category),
                const Spacer(),
                // Privacy badge
                if (memory.isPrivate) ...[
                  Icon(Lucide.EyeOff, size: 12, color: cs.onSurface.withOpacity(0.4)),
                  const SizedBox(width: 3),
                  Text(
                    l10n.memoryManagementPrivateLabel,
                    style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4)),
                  ),
                  const SizedBox(width: 8),
                ],
                // Expiry indicator
                if (memory.expiresAt != null) ...[
                  Icon(Lucide.Clock, size: 12, color: cs.error.withOpacity(0.7)),
                  const SizedBox(width: 3),
                  Text(
                    dateFmt.format(memory.expiresAt!),
                    style: TextStyle(
                        fontSize: 10, color: cs.error.withOpacity(0.7)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            // Content
            Text(
              memory.content,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, height: 1.45),
            ),

            const SizedBox(height: 8),

            // Bottom row: concepts + source + date + actions
            Row(
              children: [
                // Concepts as tags
                if (memory.concepts.isNotEmpty)
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: memory.concepts
                            .take(5)
                            .map((c) => Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: cs.primary.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '#$c',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: cs.primary.withOpacity(0.8)),
                                    ),
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  )
                else
                  const Spacer(),

                // Source label
                Text(
                  _sourceLabel(memory.source, l10n),
                  style: TextStyle(
                      fontSize: 10, color: cs.onSurface.withOpacity(0.4)),
                ),
                const SizedBox(width: 6),
                Text(
                  '·',
                  style: TextStyle(
                      fontSize: 10, color: cs.onSurface.withOpacity(0.3)),
                ),
                const SizedBox(width: 6),
                // Date
                Text(
                  dateFmt.format(memory.updatedAt),
                  style: TextStyle(
                      fontSize: 10, color: cs.onSurface.withOpacity(0.4)),
                ),
                const SizedBox(width: 8),
                // Privacy toggle / Edit / Delete
                _SmallIconButton(
                  icon: memory.isPrivate ? Lucide.Eye : Lucide.EyeOff,
                  color: cs.onSurface.withOpacity(0.5),
                  onTap: onTogglePrivate,
                ),
                const SizedBox(width: 4),
                _SmallIconButton(
                  icon: Lucide.Pencil,
                  color: cs.primary,
                  onTap: onEdit,
                ),
                const SizedBox(width: 4),
                _SmallIconButton(
                  icon: Lucide.Trash2,
                  color: cs.error,
                  onTap: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _categoryChip(BuildContext context, MemoryCategory cat) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final page = context.findAncestorStateOfType<_MemoryManagementPageState>()!;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFF2F3F5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(page._categoryIcon(cat), size: 11, color: cs.onSurface.withOpacity(0.6)),
          const SizedBox(width: 3),
          Text(
            page._categoryLabel(cat, l10n),
            style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.6)),
          ),
        ],
      ),
    );
  }

  String _sourceLabel(MemorySource src, AppLocalizations l10n) {
    switch (src) {
      case MemorySource.aiAuto:
        return l10n.memoryManagementSourceAiAuto;
      case MemorySource.aiTool:
        return l10n.memoryManagementSourceAiTool;
      case MemorySource.userManual:
        return l10n.memoryManagementSourceManual;
      case MemorySource.system:
        return l10n.memoryManagementSourceSystem;
    }
  }
}

/// Compact icon button for card actions.
class _SmallIconButton extends StatefulWidget {
  const _SmallIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_SmallIconButton> createState() => _SmallIconButtonState();
}

class _SmallIconButtonState extends State<_SmallIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: () {
        Haptics.light();
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          widget.icon,
          size: 16,
          color: _pressed ? widget.color.withOpacity(0.6) : widget.color,
        ),
      ),
    );
  }
}

/// Filter chip for category selection.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withOpacity(0.12)
              : (isDark ? Colors.white10 : const Color(0xFFF2F3F5)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? cs.primary.withOpacity(0.4)
                : cs.outlineVariant.withOpacity(0.15),
            width: 0.6,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? cs.primary : cs.onSurface.withOpacity(0.7),
          ),
        ),
      ),
    );
  }
}

/// Sort toggle button.
class _SortToggle extends StatelessWidget {
  const _SortToggle({
    required this.sortByImportance,
    required this.onToggle,
  });
  final bool sortByImportance;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: sortByImportance
          ? l10n.memoryManagementSortByDate
          : l10n.memoryManagementSortByImportance,
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Lucide.ArrowUpDown, size: 13, color: cs.primary),
              const SizedBox(width: 4),
              Text(
                sortByImportance
                    ? l10n.memoryManagementSortImportance
                    : l10n.memoryManagementSortDate,
                style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
