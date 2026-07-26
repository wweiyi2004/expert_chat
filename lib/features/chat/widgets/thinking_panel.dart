import 'package:flutter/material.dart';

/// Collapsible panel that shows the model's chain-of-thought, mimicking the
/// "深度思考" experience on chat.deepseek.com. Shows a live/elapsed timer and
/// auto-collapses once the model finishes thinking and starts answering.
class ThinkingPanel extends StatefulWidget {
  const ThinkingPanel({
    super.key,
    required this.reasoning,
    required this.isStreaming,
    this.thinkingMillis = 0,
  });

  /// The accumulated chain-of-thought text.
  final String reasoning;

  /// Whether the reasoning phase is still streaming (true → live timer + pulse).
  final bool isStreaming;

  /// Final reasoning duration in ms; 0 while still thinking.
  final int thinkingMillis;

  @override
  State<ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<ThinkingPanel>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;
  // Distinguishes a user's manual toggle from the automatic collapse-on-done.
  bool _userToggled = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isStreaming;
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.isStreaming) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ThinkingPanel old) {
    super.didUpdateWidget(old);
    if (old.isStreaming && !widget.isStreaming) {
      _pulse.stop();
      // Auto-collapse when thinking finishes, unless the user took control.
      if (!_userToggled) {
        setState(() => _expanded = false);
      }
    } else if (!old.isStreaming && widget.isStreaming) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String get _label {
    if (widget.isStreaming) return '正在深度思考…';
    final secs = (widget.thinkingMillis / 1000).round();
    if (secs <= 0) return '已深度思考';
    return '已深度思考 $secs 秒';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.secondary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() {
              _expanded = !_expanded;
              _userToggled = true;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  widget.isStreaming
                      ? FadeTransition(
                          opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
                          child: Icon(
                            Icons.psychology,
                            size: 18,
                            color: scheme.secondary,
                          ),
                        )
                      : Icon(
                          Icons.psychology_outlined,
                          size: 18,
                          color: scheme.secondary,
                        ),
                  const SizedBox(width: 8),
                  Text(
                    _label,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                widget.reasoning,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.88),
                ),
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
          ),
        ],
      ),
    );
  }
}
