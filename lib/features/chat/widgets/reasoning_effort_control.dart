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
    this.config,
  });
  final LlmConfig? config;
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
          config: config,
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
    this.config,
  });
  final LlmConfig? config;
  final bool thinking, supportsEffort;
  final ReasoningEffort effort;
  final VoidCallback onToggle;
  final ValueChanged<ReasoningEffort>? onChanged;
  @override
  State<ReasoningEffortSlider> createState() => _ReasoningEffortSliderState();
}

class _ReasoningEffortSliderState extends State<ReasoningEffortSlider> {
  List<ReasoningEffort> get _efforts => widget.config == null
      ? const [ReasoningEffort.low, ReasoningEffort.high, ReasoningEffort.max]
      : reasoningEffortsFor(widget.config!);
  bool get _canDisable =>
      widget.config == null ||
      widget.config!.capabilities.reasoningCanBeDisabled ||
      widget.config!.capabilities.sendThinkingField ||
      !widget.config!.capabilities.isReasoner;
  bool get _separateToggle => widget.config != null && widget.supportsEffort;
  int get _offset => _canDisable && !_separateToggle ? 1 : 0;
  double _initialValue() {
    if (!widget.thinking && _canDisable && !_separateToggle) return 0;
    if (!widget.supportsEffort) return _canDisable ? 1 : 0;
    final index = _efforts.indexOf(widget.effort);
    return ((index < 0
                ? _efforts
                      .indexOf(ReasoningEffort.high)
                      .clamp(0, _efforts.length - 1)
                : index) +
            _offset)
        .toDouble();
  }

  late double _value = _initialValue();
  @override
  void didUpdateWidget(covariant ReasoningEffortSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config?.model != widget.config?.model ||
        oldWidget.effort != widget.effort ||
        oldWidget.thinking != widget.thinking ||
        oldWidget.supportsEffort != widget.supportsEffort) {
      _value = _initialValue();
      _committedThinking = null;
    }
  }

  List<String> get _labels => widget.supportsEffort
      ? [
          if (_canDisable && !_separateToggle) '关闭',
          ..._efforts.map((e) => e.label),
        ]
      : ['标准', '深度思考'];
  bool? _committedThinking;
  void _commit(double value) {
    final index = value.round();
    final thinking = _separateToggle || !_canDisable || index > 0;
    if (thinking != (_committedThinking ?? widget.thinking)) {
      _committedThinking = thinking;
      widget.onToggle();
    }
    if (thinking && widget.supportsEffort) {
      widget.onChanged?.call(_efforts[index - _offset]);
    }
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
            if (_separateToggle && _canDisable)
              SwitchListTile.adaptive(
                key: const ValueKey('reasoning-thinking-toggle'),
                contentPadding: EdgeInsets.zero,
                title: const Text('深度思考'),
                value: _committedThinking ?? widget.thinking,
                onChanged: (value) {
                  if (value != (_committedThinking ?? widget.thinking)) {
                    setState(() => _committedThinking = value);
                    widget.onToggle();
                  }
                },
              ),
            Text(
              _labels[_value.round()],
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (_labels.length > 1)
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
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 19,
                  ),
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
