import 'package:flutter/material.dart';

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
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Semantics(
            key: const ValueKey('chat-work-mode-switch'),
            label: workMode ? '工作模式：分步执行并交付结果' : '聊天模式：问答与讨论',
            child: prominent
                ? Container(
                    width: 230,
                    height: 44,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(26),
                    ),
                    child: Row(
                      children: [
                        for (final value in [false, true])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 1,
                              ),
                              child: Semantics(
                                selected: workMode == value,
                                child: TextButton(
                                  onPressed: onChanged == null
                                      ? null
                                      : () => onChanged!(value),
                                  style: TextButton.styleFrom(
                                    backgroundColor: workMode == value
                                        ? colors.surface
                                        : Colors.transparent,
                                    foregroundColor: colors.onSurface,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(24),
                                    ),
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  child: Text(value ? '工作' : '聊天'),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                : SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 8),
                      ),
                      minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
                      textStyle: WidgetStatePropertyAll(
                        Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    segments: const [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('聊天'),
                        tooltip: '问答、讨论与轻量搜索',
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('工作'),
                        tooltip: '多步执行、文件交付与已连接工具',
                      ),
                    ],
                    selected: {workMode},
                    onSelectionChanged: onChanged == null
                        ? null
                        : (selection) => onChanged!(selection.first),
                    emptySelectionAllowed: false,
                  ),
          ),
        ),
        if (workMode && onWorkOptions != null)
          IconButton(
            tooltip: '工作选项',
            onPressed: onChanged == null ? null : onWorkOptions,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.expand_more, size: 20),
          ),
      ],
    );
  }
}
