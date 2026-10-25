import 'package:flutter/material.dart';
import '../../../core/theme.dart';

/// Retains keyed rows while their layout position changes. Only the visual
/// translation is animated; hit testing always follows the visible row.
class SidebarReorderMotion extends StatefulWidget {
  const SidebarReorderMotion({super.key, required this.child});
  final Widget child;
  @override
  State<SidebarReorderMotion> createState() => _SidebarReorderMotionState();
}

class _SidebarReorderMotionState extends State<SidebarReorderMotion>
    with SingleTickerProviderStateMixin {
  final _positionKey = GlobalKey();
  late final _controller = AnimationController(
    vsync: this,
    duration: AppMetrics.motionReorder,
  );
  double? _previous;
  double _delta = 0;
  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(covariant SidebarReorderMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _measure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _delta = 0;
    }
  }

  void _measure() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    final box = _positionKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    var scrollOffset = 0.0;
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        scrollOffset += (element.state as ScrollableState).position.pixels;
      }
      return true;
    });
    // Position in scroll content, so merely scrolling cannot animate a row.
    final next = box.localToGlobal(Offset.zero).dy + scrollOffset;
    final prior = _previous;
    _previous = next;
    if (prior != null &&
        (prior - next).abs() > .5 &&
        !MediaQuery.disableAnimationsOf(context)) {
      _delta = (prior - next).clamp(-600, 600);
      _controller.forward(from: 0);
    }
  });
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: _positionKey,
    child: AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (_, child) => Transform.translate(
        offset: Offset(
          0,
          MediaQuery.disableAnimationsOf(context)
              ? 0
              : _delta *
                    (1 - AppMetrics.motionCurve.transform(_controller.value)),
        ),
        child: child,
      ),
    ),
  );
}
