import 'package:flutter/material.dart';
import '../../../domain/context/context_window_manager.dart';

class ContextUsageChip extends StatelessWidget {
  const ContextUsageChip({
    super.key,
    required this.report,
    required this.inputBudget,
    this.compact = false,
  });

  final ContextWindowReport? report;
  final int inputBudget;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = report?.sentTokens ?? 0;
    final budget = report?.inputBudgetTokens ?? inputBudget;
    final fraction = budget <= 0 ? 0.0 : (current / budget).clamp(0.0, 1.0);
    final managed = report?.managed ?? false;
    final pct = (fraction * 100).round();
    final color = fraction >= 0.9
        ? scheme.error
        : fraction >= 0.7
        ? scheme.tertiary
        : scheme.primary;

    final detail = report == null
        ? '上下文预算 ${_compactTokens(budget)}（发送后显示本轮用量）'
        : report!.userFacingNote;

    // Compact label for the app bar.
    String label;
    if (report == null) {
      label = _compactTokens(budget);
    } else if (managed) {
      final bits = <String>[
        '$pct%',
        if (report!.droppedMessages > 0) '−${report!.droppedMessages}',
        if (report!.summaryInjected) '摘要',
      ];
      label = bits.join(' · ');
    } else {
      label = '$pct%';
    }

    return Semantics(
      key: const ValueKey('chat-context-usage'),
      label: detail,
      value: '$pct%',
      excludeSemantics: true,
      child: Tooltip(
        message: detail,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: managed
                ? color.withValues(alpha: 0.12)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
            border: managed
                ? Border.all(color: color.withValues(alpha: 0.28))
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  semanticsLabel: detail,
                  semanticsValue: '$pct%',
                  value: fraction,
                  strokeWidth: 2,
                  color: color,
                  backgroundColor: scheme.outlineVariant,
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: managed ? color : scheme.onSurfaceVariant,
                    fontWeight: managed ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _compactTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)}K';
    }
    return '$value';
  }
}
