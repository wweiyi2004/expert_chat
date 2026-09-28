import 'package:flutter/material.dart';

class ChatWorkModeSwitch extends StatelessWidget {
  const ChatWorkModeSwitch({super.key, required this.workMode, this.onChanged});

  final bool workMode;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('chat-work-mode-switch'),
      label: workMode ? '任务模式' : '对话模式',
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 8),
          ),
          minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
          textStyle: WidgetStatePropertyAll(
            Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        segments: const [
          ButtonSegment<bool>(value: false, label: Text('对话')),
          ButtonSegment<bool>(value: true, label: Text('任务')),
        ],
        selected: {workMode},
        onSelectionChanged: onChanged == null
            ? null
            : (selection) => onChanged!(selection.first),
        emptySelectionAllowed: false,
      ),
    );
  }
}
