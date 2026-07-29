import 'package:flutter/material.dart';

import '../../domain/memory/memory_entry.dart';
import '../../domain/memory/memory_transfer.dart';

/// Offline preview for a memory backup merge. Safe new entries are selected by
/// default; conflicts keep the current version until the user chooses.
class MemoryImportReviewSheet extends StatefulWidget {
  const MemoryImportReviewSheet({super.key, required this.plan});

  final MemoryImportPlan plan;

  @override
  State<MemoryImportReviewSheet> createState() =>
      _MemoryImportReviewSheetState();
}

class _MemoryImportReviewSheetState extends State<MemoryImportReviewSheet> {
  final Map<String, MemoryImportAction> _choices = {};

  @override
  void initState() {
    super.initState();
    for (final item in widget.plan.items) {
      if (item.status == MemoryImportStatus.newEntry) {
        _choices[item.imported.id] = MemoryImportAction.add;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actionable = widget.plan.actionableItems;
    final selections = [
      for (final item in actionable)
        if (_choices[item.imported.id] case final action?)
          MemoryImportSelection(item: item, action: action),
    ];

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.92,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Material(
              color: scheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 10),
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Row(
                      children: [
                        Icon(Icons.restore_rounded, color: scheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '预览记忆备份',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _countChip(
                          context,
                          '新增 ${widget.plan.newCount}',
                          scheme.primaryContainer,
                        ),
                        _countChip(
                          context,
                          '重复 ${widget.plan.duplicateCount}',
                          scheme.surfaceContainerHighest,
                        ),
                        _countChip(
                          context,
                          '不同版本 ${widget.plan.conflictCount}',
                          scheme.tertiaryContainer,
                        ),
                        if (widget.plan.blockedCount > 0)
                          _countChip(
                            context,
                            '已拦截 ${widget.plan.blockedCount}',
                            scheme.errorContainer,
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                    child: Text(
                      '新增项已勾选；重复项自动跳过；不同版本默认保留手机中的当前记忆。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: actionable.isEmpty
                        ? const Center(child: Text('没有需要合并的记忆'))
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                            itemCount: actionable.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final item = actionable[index];
                              return item.status == MemoryImportStatus.newEntry
                                  ? _newEntryCard(context, item)
                                  : _conflictCard(context, item);
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      border: Border(
                        top: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            selections.isEmpty
                                ? '不会修改现有记忆'
                                : '将应用 ${selections.length} 项',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: selections.isEmpty
                              ? null
                              : () => Navigator.of(context).pop(selections),
                          icon: const Icon(Icons.merge_rounded, size: 18),
                          label: Text('合并 ${selections.length} 项'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _newEntryCard(BuildContext context, MemoryImportItem item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _choices[item.imported.id] == MemoryImportAction.add;
    return Card(
      elevation: 0,
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.34)
          : scheme.surfaceContainerLow,
      child: CheckboxListTile(
        value: selected,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.fromLTRB(10, 5, 14, 7),
        title: Text(item.imported.content),
        subtitle: Text(item.imported.pinned ? '常驻记忆' : '按需召回'),
        onChanged: (value) {
          setState(() {
            if (value == true) {
              _choices[item.imported.id] = MemoryImportAction.add;
            } else {
              _choices.remove(item.imported.id);
            }
          });
        },
      ),
    );
  }

  Widget _conflictCard(BuildContext context, MemoryImportItem item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final existing = item.existing!;
    final choice = _choices[item.imported.id];
    final contentsDiffer =
        _contentKey(existing.content) != _contentKey(item.imported.content);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.tertiary.withValues(alpha: 0.55)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.compare_arrows_rounded, color: scheme.tertiary),
                const SizedBox(width: 8),
                Text(
                  '同一条记忆存在不同版本',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.tertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _versionBox(
              context,
              title: '当前版本',
              entry: existing,
              color: scheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 8),
            _versionBox(
              context,
              title: '备份版本',
              entry: item.imported,
              color: scheme.tertiaryContainer.withValues(alpha: 0.45),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: ValueKey('keep-current-${item.imported.id}'),
                  selected: choice == null,
                  onSelected: (_) =>
                      setState(() => _choices.remove(item.imported.id)),
                  label: const Text('保留当前'),
                ),
                ChoiceChip(
                  key: ValueKey('use-backup-${item.imported.id}'),
                  selected: choice == MemoryImportAction.useImported,
                  onSelected: (_) => setState(
                    () => _choices[item.imported.id] =
                        MemoryImportAction.useImported,
                  ),
                  label: const Text('使用备份'),
                ),
                if (contentsDiffer)
                  ChoiceChip(
                    key: ValueKey('keep-both-${item.imported.id}'),
                    selected: choice == MemoryImportAction.keepBoth,
                    onSelected: (_) => setState(
                      () => _choices[item.imported.id] =
                          MemoryImportAction.keepBoth,
                    ),
                    label: const Text('两条都保留'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionBox(
    BuildContext context, {
    required String title,
    required MemoryEntry entry,
    required Color color,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            entry.content,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            entry.pinned ? '常驻记忆' : '按需召回',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Widget _countChip(BuildContext context, String label, Color color) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }

  static String _contentKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}
