import 'package:flutter/material.dart';
import '../../../core/prototype_widgets.dart';

class ChatWorkModeSwitch extends StatelessWidget {
  const ChatWorkModeSwitch({
    super.key,
    required this.workMode,
    this.onChanged,
    this.onWorkOptions,
    this.prominent = false,
  });

  final bool workMode;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onWorkOptions;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('chat-work-mode-switch'),
      label: workMode ? '工作模式：分步执行并交付结果' : '聊天模式：问答与讨论',
      child: PrototypeSegmentedControl<bool>(
        segments: const [
          PrototypeSegment(value: false, label: '聊天'),
          PrototypeSegment(value: true, label: '工作'),
        ],
        value: workMode,
        onChanged: onChanged,
      ),
    );
  }
}
