import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/theme.dart';

enum ExecutionVisualStatus {
  running,
  waiting,
  completedUnseen,
  completed,
  failed,
  paused,
  idle,
  queued;

  String get label => switch (this) {
    running => '执行中',
    waiting => '等待确认',
    completedUnseen => '已完成 · 未查看',
    completed => '完成',
    failed => '执行失败',
    paused => '已暂停',
    idle => '空闲',
    queued => '排队',
  };
}

Color executionStatusColor(BuildContext context, ExecutionVisualStatus status) {
  final colors = AppStatusColors.of(context);
  return switch (status) {
    ExecutionVisualStatus.running => colors.running,
    ExecutionVisualStatus.waiting ||
    ExecutionVisualStatus.failed => colors.confirmation,
    ExecutionVisualStatus.completed => colors.completed,
    ExecutionVisualStatus.completedUnseen => Theme.of(
      context,
    ).colorScheme.primary,
    _ => colors.faint,
  };
}

/// Reduced motion stops the ticker instead of only hiding its changing value.
class ExecutionStatusIndicator extends StatefulWidget {
  const ExecutionStatusIndicator({
    super.key,
    required this.status,
    this.size = 12,
    this.color,
  });
  final ExecutionVisualStatus status;
  final double size;
  final Color? color;
  @override
  State<ExecutionStatusIndicator> createState() =>
      _ExecutionStatusIndicatorState();
}

class _ExecutionStatusIndicatorState extends State<ExecutionStatusIndicator>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(vsync: this);
  bool _reduce = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.disableAnimationsOf(context);
    _configure();
  }

  @override
  void didUpdateWidget(ExecutionStatusIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _configure();
  }

  void _configure() {
    _motion.stop();
    _motion.value = 0;
    if (_reduce) return;
    switch (widget.status) {
      case ExecutionVisualStatus.running:
        _motion.duration = const Duration(milliseconds: 800);
        _motion.repeat();
      case ExecutionVisualStatus.queued:
        _motion.duration = const Duration(seconds: 4);
        _motion.repeat();
      case ExecutionVisualStatus.waiting:
        _motion.duration = const Duration(milliseconds: 900);
        _motion.repeat(reverse: true);
      case ExecutionVisualStatus.completed:
        _motion.duration = const Duration(milliseconds: 300);
        _motion.forward();
      default:
        break;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final color = widget.color ?? executionStatusColor(context, status);
    return Semantics(
      label: status.label,
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _motion,
          builder: (context, _) {
            final value = _reduce ? 0.0 : _motion.value;
            Widget mark = switch (status) {
              ExecutionVisualStatus.running ||
              ExecutionVisualStatus.queued => Transform.rotate(
                angle: value * math.pi * 2,
                child: CustomPaint(
                  painter: _StatusRingPainter(
                    color,
                    status == ExecutionVisualStatus.queued,
                  ),
                ),
              ),
              ExecutionVisualStatus.completed => Transform.scale(
                scale: _reduce
                    ? 1
                    : 0.3 + 0.7 * Curves.easeOutBack.transform(value),
                child: Icon(
                  Icons.check_rounded,
                  size: widget.size,
                  color: color,
                ),
              ),
              ExecutionVisualStatus.failed => Icon(
                Icons.close_rounded,
                size: widget.size,
                color: color,
              ),
              _ => Center(
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
              ),
            };
            if (status == ExecutionVisualStatus.waiting) {
              mark = Opacity(
                opacity: 1 - .65 * value,
                child: Transform.scale(scale: 1 - .25 * value, child: mark),
              );
            }
            return mark;
          },
        ),
      ),
    );
  }
}

class _StatusRingPainter extends CustomPainter {
  const _StatusRingPainter(this.color, this.dashed);
  final Color color;
  final bool dashed;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (dashed) {
      for (var i = 0; i < 8; i++) {
        canvas.drawArc(rect, i * math.pi / 4, math.pi / 8, false, paint);
      }
    } else {
      canvas.drawArc(rect, -math.pi / 2, math.pi, false, paint);
    }
  }

  @override
  bool shouldRepaint(_StatusRingPainter old) =>
      old.color != color || old.dashed != dashed;
}

class ExecutionStatusCapsule extends StatelessWidget {
  const ExecutionStatusCapsule({super.key, required this.status, this.label});
  final ExecutionVisualStatus status;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final colors = AppStatusColors.of(context);
    final color = executionStatusColor(context, status);
    final soft = switch (status) {
      ExecutionVisualStatus.running => colors.runningSoft,
      ExecutionVisualStatus.waiting ||
      ExecutionVisualStatus.failed => colors.confirmationSoft,
      ExecutionVisualStatus.completed => colors.completedSoft,
      _ => Theme.of(context).colorScheme.surfaceContainerHighest,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExecutionStatusIndicator(status: status),
          const SizedBox(width: 6),
          Text(
            label ?? status.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
