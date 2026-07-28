import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Rainbow ripple expanding from [origin] (local to this overlay).
class ResearchModeRippleOverlay extends StatefulWidget {
  const ResearchModeRippleOverlay({
    super.key,
    required this.playing,
    required this.onFinished,
    this.origin,
  });

  final bool playing;

  /// Expansion center in this overlay's local coordinates.
  /// Null → geometric center of the screen.
  final Offset? origin;
  final VoidCallback onFinished;

  @override
  State<ResearchModeRippleOverlay> createState() =>
      _ResearchModeRippleOverlayState();
}

class _ResearchModeRippleOverlayState extends State<ResearchModeRippleOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// Slow, readable pulse (~2.8s).
  static const _duration = Duration(milliseconds: 2800);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _duration);
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onFinished();
      }
    });
    if (widget.playing) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant ResearchModeRippleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !oldWidget.playing) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.playing && !_ctrl.isAnimating) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          // Ease-out so early rings crawl, later settle gently.
          final t = Curves.easeOutCubic.transform(_ctrl.value);
          // Soft fade in, long hold, long fade out.
          final opacity = t < 0.12
              ? (t / 0.12) * 0.62
              : t > 0.72
              ? ((1 - t) / 0.28) * 0.62
              : 0.62;
          return CustomPaint(
            painter: _RainbowRipplePainter(
              progress: t,
              opacity: opacity.clamp(0.0, 0.75),
              origin: widget.origin,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _RainbowRipplePainter extends CustomPainter {
  _RainbowRipplePainter({
    required this.progress,
    required this.opacity,
    required this.origin,
  });

  final double progress;
  final double opacity;
  final Offset? origin;

  /// Spectral band (ROYGBIV-ish).
  static const _spectrum = <Color>[
    Color(0xFFFF3B30), // red
    Color(0xFFFF9500), // orange
    Color(0xFFFFCC00), // yellow
    Color(0xFF34C759), // green
    Color(0xFF5AC8FA), // cyan
    Color(0xFF007AFF), // blue
    Color(0xFFAF52DE), // purple
    Color(0xFFFF2D55), // magenta back toward red
  ];

  Color _spectrumAt(double t) {
    final x = (t % 1.0) * (_spectrum.length - 1);
    final i = x.floor().clamp(0, _spectrum.length - 2);
    final f = x - i;
    return Color.lerp(_spectrum[i], _spectrum[i + 1], f)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center =
        origin ?? Offset(size.width * 0.5, size.height * 0.5);
    final maxR =
        math.sqrt(
          math.max(center.dx, size.width - center.dx) *
                  math.max(center.dx, size.width - center.dx) +
              math.max(center.dy, size.height - center.dy) *
                  math.max(center.dy, size.height - center.dy),
        ) *
        1.15;

    // Gentle full-screen wash that cycles hue once.
    final wash = _spectrumAt(progress).withValues(alpha: opacity * 0.18);
    canvas.drawRect(Offset.zero & size, Paint()..color = wash);

    // Multiple rainbow rings with staggered phase.
    const ringCount = 6;
    for (var i = 0; i < ringCount; i++) {
      final lag = i * 0.07;
      final phase = ((progress - lag) / (1 - lag * 0.5)).clamp(0.0, 1.0);
      if (phase <= 0) continue;
      final r = maxR * Curves.easeOutQuart.transform(phase);
      final ringAlpha = (1 - phase) * opacity * 0.95;
      if (ringAlpha <= 0.02) continue;

      // Hue shifts along the ring index and time.
      final hueT = (phase * 0.55 + i / ringCount + progress * 0.35) % 1.0;
      final color = _spectrumAt(hueT);

      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (22 - i * 2.2).clamp(6.0, 22.0)
        ..color = color.withValues(alpha: ringAlpha * 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawCircle(center, r, stroke);

      final fill = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: ringAlpha * 0.28),
            _spectrumAt((hueT + 0.15) % 1.0).withValues(alpha: ringAlpha * 0.12),
            color.withValues(alpha: 0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r * 0.96, fill);
    }

    // Bright core pulse at the switch.
    final coreT = (1 - (progress - 0.05).abs() * 2).clamp(0.0, 1.0);
    if (coreT > 0) {
      final coreR = 28 + 40 * (1 - coreT);
      final corePaint = Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.55 * coreT * opacity),
            _spectrumAt(progress).withValues(alpha: 0.35 * coreT * opacity),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: coreR));
      canvas.drawCircle(center, coreR, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RainbowRipplePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.opacity != opacity ||
      oldDelegate.origin != origin;
}
