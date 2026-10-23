import 'dart:math' as math;
import 'package:flutter/material.dart';

/// An indeterminate execution indicator; no progress percentage is implied.
class ExecutionRing extends StatefulWidget {
  const ExecutionRing({super.key, this.size = 15, this.color});
  final double size;
  final Color? color;
  @override
  State<ExecutionRing> createState() => _ExecutionRingState();
}

class _ExecutionRingState extends State<ExecutionRing>
    with SingleTickerProviderStateMixin {
  late final _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  )..repeat();
  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: '执行中',
    child: RotationTransition(
      turns: _rotation,
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _RingPainter(
          widget.color ?? Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1.2);
    canvas.drawOval(
      rect,
      Paint()
        ..color = color.withValues(alpha: .18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawArc(
      rect,
      -.5 * math.pi,
      1.25 * math.pi,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}
