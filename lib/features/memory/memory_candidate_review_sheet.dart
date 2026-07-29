import 'package:flutter/material.dart';

import '../../domain/memory/memory_candidate_service.dart';

/// Explicit confirmation gate between AI extraction and file persistence.
///
/// Nothing is pre-selected. New facts require a checkbox; updates/conflicts
/// require choosing replace or keep-both while showing every affected entry.
class MemoryCandidateReviewSheet extends StatefulWidget {
  const MemoryCandidateReviewSheet({super.key, required this.candidates});

  final List<MemoryCandidate> candidates;

  @override
  State<MemoryCandidateReviewSheet> createState() =>
      _MemoryCandidateReviewSheetState();
}

class _MemoryCandidateReviewSheetState
    extends State<MemoryCandidateReviewSheet> {
  final Map<String, MemoryCandidateWriteMode> _choices = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selections = [
      for (final candidate in widget.candidates)
        if (_choices[candidate.id] case final mode?)
          MemoryCandidateSelection(candidate: candidate, mode: mode),
    ];

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.9,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
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
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_outlined,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '确认候选记忆',
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
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                    child: Text(
                      '新记忆需要勾选；发现旧记忆可能过时时，请选择替换、两条都保留或暂不保存。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                      itemCount: widget.candidates.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _candidateCard(context, widget.candidates[index]),
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
                                ? '尚未选择'
                                : '已选择 ${selections.length} 条',
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
                          icon: const Icon(Icons.save_outlined, size: 18),
                          label: Text('保存 ${selections.length} 条'),
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

  Widget _candidateCard(BuildContext context, MemoryCandidate candidate) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final choice = _choices[candidate.id];
    final selected = choice != null;

    return Card(
      elevation: 0,
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.35)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: candidate.hasExistingRelation
              ? scheme.tertiary.withValues(alpha: 0.55)
              : selected
              ? scheme.primary.withValues(alpha: 0.45)
              : scheme.outlineVariant,
        ),
      ),
      child: candidate.hasExistingRelation
          ? _relatedCandidate(context, candidate, choice)
          : CheckboxListTile(
              value: choice == MemoryCandidateWriteMode.add,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.fromLTRB(10, 6, 14, 8),
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _choices[candidate.id] = MemoryCandidateWriteMode.add;
                  } else {
                    _choices.remove(candidate.id);
                  }
                });
              },
              title: Text(
                candidate.content,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: _candidateMeta(context, candidate),
            ),
    );
  }

  Widget _relatedCandidate(
    BuildContext context,
    MemoryCandidate candidate,
    MemoryCandidateWriteMode? choice,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                candidate.relation == MemoryCandidateRelation.conflict
                    ? Icons.warning_amber_rounded
                    : Icons.update_rounded,
                size: 20,
                color: scheme.tertiary,
              ),
              const SizedBox(width: 8),
              Text(
                candidate.relation.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.tertiary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _categoryPill(context, candidate),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '新说法',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            candidate.content,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer.withValues(alpha: 0.42),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '当前记忆',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                for (final memory in candidate.relatedMemories)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${memory.content}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (candidate.reason.isNotEmpty) ...[
            const SizedBox(height: 9),
            Text(
              candidate.reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: ValueKey('replace-${candidate.id}'),
                selected: choice == MemoryCandidateWriteMode.replace,
                onSelected: (_) => setState(
                  () =>
                      _choices[candidate.id] = MemoryCandidateWriteMode.replace,
                ),
                avatar: const Icon(Icons.swap_horiz_rounded, size: 17),
                label: const Text('替换旧记忆'),
              ),
              ChoiceChip(
                key: ValueKey('keep-both-${candidate.id}'),
                selected: choice == MemoryCandidateWriteMode.add,
                onSelected: (_) => setState(
                  () => _choices[candidate.id] = MemoryCandidateWriteMode.add,
                ),
                avatar: const Icon(Icons.add_circle_outline, size: 17),
                label: const Text('两条都保留'),
              ),
              ChoiceChip(
                key: ValueKey('ignore-${candidate.id}'),
                selected: choice == null,
                onSelected: (_) =>
                    setState(() => _choices.remove(candidate.id)),
                label: const Text('暂不保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _candidateMeta(BuildContext context, MemoryCandidate candidate) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _categoryPill(context, candidate),
          if (candidate.reason.isNotEmpty)
            Text(
              candidate.reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryPill(BuildContext context, MemoryCandidate candidate) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          candidate.category.label,
          style: theme.textTheme.labelSmall,
        ),
      ),
    );
  }
}
