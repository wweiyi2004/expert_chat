import 'package:flutter/material.dart';
import '../../../domain/llm/llm_provider.dart';

class ReasoningEffortControl extends StatelessWidget {
  const ReasoningEffortControl({
    super.key,
    required this.enabled,
    required this.thinking,
    required this.effort,
    required this.supportsEffort,
    required this.onToggle,
    this.onChanged,
    this.compact = false,
  });
  final bool compact;
  final bool enabled, thinking, supportsEffort;
  final ReasoningEffort effort;
  final VoidCallback onToggle;
  final ValueChanged<ReasoningEffort>? onChanged;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuAnchor(
      style: MenuStyle(
        elevation: const WidgetStatePropertyAll(8),
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      menuChildren: [
        ReasoningEffortSlider(
          thinking: thinking,
          effort: effort,
          supportsEffort: supportsEffort,
          onToggle: onToggle,
          onChanged: onChanged,
        ),
      ],
      builder: (context, menu, _) => compact
          ? IconButton(
              key: const ValueKey('desktop-composer-options'),
              tooltip: thinking
                  ? '思考强度 · ${supportsEffort ? effort.label : '深度思考'}'
                  : '思考强度',
              onPressed: enabled
                  ? () => menu.isOpen ? menu.close() : menu.open()
                  : null,
              icon: const Icon(Icons.psychology_outlined, size: 18),
              style: IconButton.styleFrom(
                minimumSize: const Size.square(32),
                maximumSize: const Size.square(32),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            )
          : TextButton(
              key: const ValueKey('desktop-composer-options'),
              onPressed: enabled
                  ? () => menu.isOpen ? menu.close() : menu.open()
                  : null,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                backgroundColor: scheme.surfaceContainerHighest.withValues(
                  alpha: .5,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 34),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    thinking
                        ? (supportsEffort ? effort.label : '深度思考')
                        : '思考强度',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(width: 5),
                  const Icon(Icons.keyboard_arrow_down, size: 16),
                ],
              ),
            ),
    );
  }
}

class ReasoningEffortSlider extends StatefulWidget {
  const ReasoningEffortSlider({
    super.key,
    required this.thinking,
    required this.effort,
    required this.supportsEffort,
    required this.onToggle,
    this.onChanged,
  });
  final bool thinking, supportsEffort;
  final ReasoningEffort effort;
  final VoidCallback onToggle;
  final ValueChanged<ReasoningEffort>? onChanged;
  @override
  State<ReasoningEffortSlider> createState() => _ReasoningEffortSliderState();
}

class _ReasoningEffortSliderState extends State<ReasoningEffortSlider> {
  late double _value = widget.thinking
      ? (widget.supportsEffort ? widget.effort.index + 1.0 : 1.0)
      : 0;
  List<String> get _labels => widget.supportsEffort
      ? ['标准', ...ReasoningEffort.values.map((e) => e.label)]
      : ['标准', '深度思考'];
  bool? _committedThinking;
  void _commit(double value) {
    final index = value.round();
    if ((index > 0) != (_committedThinking ?? widget.thinking)) {
      _committedThinking = index > 0;
      widget.onToggle();
    }
    if (index > 0 && widget.supportsEffort)
      widget.onChanged?.call(ReasoningEffort.values[index - 1]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _labels[_value.round()],
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 26,
                activeTrackColor: colors.primary,
                inactiveTrackColor: colors.surfaceContainerHighest,
                thumbColor: colors.surface,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 14,
                  elevation: 2,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 19),
                activeTickMarkColor: colors.onPrimary.withValues(alpha: .45),
                inactiveTickMarkColor: colors.onSurfaceVariant.withValues(
                  alpha: .35,
                ),
              ),
              child: Slider(
                key: const ValueKey('reasoning-effort-slider'),
                min: 0,
                max: (_labels.length - 1).toDouble(),
                divisions: _labels.length - 1,
                value: _value,
                label: _labels[_value.round()],
                onChanged: (value) => setState(() => _value = value),
                onChangeEnd: _commit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
