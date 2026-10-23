import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Resizable list/detail panes; each pane owns its scrolling and stays clipped.
class WorkbenchSplitView extends StatefulWidget {
  const WorkbenchSplitView({
    super.key,
    required this.first,
    required this.second,
    this.breakpoint = 680,
    this.initialWidth = 260,
    this.initialFraction = .4,
  });
  final Widget first, second;
  final double breakpoint, initialWidth, initialFraction;
  @override
  State<WorkbenchSplitView> createState() => _WorkbenchSplitViewState();
}

class _WorkbenchSplitViewState extends State<WorkbenchSplitView> {
  double? _width, _fraction;
  bool _hovered = false, _dragging = false;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = constraints.maxWidth >= widget.breakpoint;
      final extent = horizontal ? constraints.maxWidth : constraints.maxHeight;
      final available = math.max(0.0, extent - 12);
      final minimum = math.min(horizontal ? 150.0 : 96.0, available / 3);
      final position =
          (horizontal
                  ? (_width ?? widget.initialWidth)
                  : available * (_fraction ?? widget.initialFraction))
              .clamp(minimum, available - minimum);
      final colors = Theme.of(context).colorScheme;
      final divider = MouseRegion(
        cursor: horizontal
            ? SystemMouseCursors.resizeLeftRight
            : SystemMouseCursors.resizeUpDown,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          label: '拖动调整两个面板大小',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () => setState(() {
              _width = null;
              _fraction = null;
            }),
            onPanStart: (_) => setState(() => _dragging = true),
            onPanEnd: (_) => setState(() => _dragging = false),
            onPanCancel: () => setState(() => _dragging = false),
            onPanUpdate: (event) => setState(() {
              final next =
                  (position + (horizontal ? event.delta.dx : event.delta.dy))
                      .clamp(minimum, available - minimum);
              if (horizontal) {
                _width = next;
              } else if (available > 0) {
                _fraction = next / available;
              }
            }),
            child: Container(
              width: horizontal ? 12 : null,
              height: horizontal ? null : 12,
              color: _hovered || _dragging
                  ? colors.primary.withValues(alpha: .10)
                  : colors.surfaceContainer,
              child: Center(
                child: Container(
                  width: horizontal ? 3 : 38,
                  height: horizontal ? 38 : 3,
                  decoration: BoxDecoration(
                    color: _hovered || _dragging
                        ? colors.primary
                        : colors.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final panes = [
        SizedBox(
          width: horizontal ? position : null,
          height: horizontal ? null : position,
          child: ClipRect(child: widget.first),
        ),
        divider,
        Expanded(child: ClipRect(child: widget.second)),
      ];
      return horizontal
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: panes)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: panes,
            );
    },
  );
}
