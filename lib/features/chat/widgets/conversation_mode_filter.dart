import 'package:flutter/material.dart';

import '../../../core/mode_style.dart';
import '../../../data/story_models.dart';

class ConversationModeFilter extends StatelessWidget {
  const ConversationModeFilter({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final ConversationMode? selected;
  final ValueChanged<ConversationMode?> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options =
        <({String id, String label, IconData icon, ConversationMode? mode})>[
          (id: 'all', label: '全部', icon: Icons.apps_rounded, mode: null),
          (
            id: ConversationMode.chat.name,
            label: ModeStyle.label(ConversationMode.chat),
            icon: ModeStyle.icon(ConversationMode.chat),
            mode: ConversationMode.chat,
          ),
        ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcons =
            constraints.maxWidth >= 264 &&
            MediaQuery.textScalerOf(context).scale(12) <= 14.4;
        return Container(
          key: const ValueKey('conversation-mode-filter'),
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
          child: Row(
            children: [
              for (var index = 0; index < options.length; index++) ...[
                if (index > 0) const SizedBox(width: 2),
                Expanded(
                  child: _ModeFilterSegment(
                    key: ValueKey(
                      'conversation-mode-filter-${options[index].id}',
                    ),
                    label: options[index].label,
                    icon: showIcons ? options[index].icon : null,
                    selected: selected == options[index].mode,
                    onTap: () => onSelected(options[index].mode),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ModeFilterSegment extends StatelessWidget {
  const _ModeFilterSegment({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label会话筛选',
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.10),
                    scheme.surface,
                  )
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.24)
                  : Colors.transparent,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.08),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: onTap,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: 5),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: foreground,
                      ),
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
}
