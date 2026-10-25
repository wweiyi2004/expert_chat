import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/theme.dart';

/// A bounded menu positioned beside the control that opened it.
Future<T?> showComposerPopover<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double width = 380,
}) {
  if (MediaQuery.sizeOf(context).width < 840) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheet).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .78,
          ),
          child: builder(sheet),
        ),
      ),
    );
  }
  final render = context.findRenderObject();
  final box = render is RenderBox ? render : null;
  final origin = box?.localToGlobal(Offset.zero) ?? Offset.zero;
  final size = box?.size ?? Size.zero;
  return showDialog<T>(
    context: context,
    useSafeArea: false,
    barrierColor: Colors.transparent,
    builder: (dialog) {
      final media = MediaQuery.of(dialog);
      final screen = media.size;
      final metrics = Theme.of(dialog).extension<AppMetrics>();
      final topEdge = math.max(
        metrics?.popoverTopMargin ?? 40.0,
        media.padding.top + 20,
      );
      final bottomEdge = math.max(
        topEdge,
        screen.height -
            math.max(media.viewInsets.bottom, media.padding.bottom) -
            20,
      );
      final usableHeight = bottomEdge - topEdge;
      final boundedWidth = math.max(0.0, math.min(width, screen.width - 24));
      final above = (origin.dy - 8).clamp(topEdge, bottomEdge);
      final below = (origin.dy + size.height + 8).clamp(topEdge, bottomEdge);
      final useAbove = above - topEdge > bottomEdge - below;
      // Keep long menus compact; scroll their contents instead of growing
      // nearly to the title bar. Recalculate when the keyboard opens.
      final maxHeight = math.max(
        0.0,
        math.min(
          math.min(
            metrics?.popoverMaxHeight ?? 420.0,
            usableHeight < 320 ? usableHeight : usableHeight * .65,
          ),
          useAbove ? above - topEdge : bottomEdge - below,
        ),
      );
      return Stack(
        children: [
          Positioned(
            left: origin.dx.clamp(
              12.0,
              math.max(12.0, screen.width - boundedWidth - 12),
            ),
            top: useAbove ? null : below,
            bottom: useAbove ? screen.height - above : null,
            width: boundedWidth,
            child: Material(
              key: const ValueKey('composer-popover-surface'),
              elevation: 6,
              color: Theme.of(dialog).colorScheme.surfaceContainer,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: Theme.of(dialog).colorScheme.outlineVariant,
                ),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: builder(dialog),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Shared title spacing and a fixed footer around a scrollable menu body.
class ComposerPopoverFrame extends StatelessWidget {
  const ComposerPopoverFrame({
    super.key,
    required this.title,
    required this.body,
    this.footer,
  });
  final String title;
  final Widget body;
  final Widget? footer;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final bodyHeight = math.max(
        96.0,
        constraints.maxHeight - 72 * scale - (footer == null ? 12 : 76 * scale),
      );
      // Keep the same subtree when the keyboard opens. In a short viewport the
      // whole frame can scroll; otherwise only its bounded body scrolls.
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: bodyHeight),
              child: body,
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                child: footer!,
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}
