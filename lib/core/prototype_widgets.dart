import 'line_icon.dart';
import 'package:flutter/material.dart';
import 'theme.dart';

/// Flat, compact visual roles from the approved HTML. Palette values and the
/// user's selected theme remain owned by AppTheme/UiPrefs.
class PrototypeColors {
  PrototypeColors._(BuildContext context)
    : surface = Theme.of(context).colorScheme.surface,
      panel = Theme.of(context).colorScheme.surfaceContainer,
      line = Theme.of(context).colorScheme.outline,
      ink = Theme.of(context).colorScheme.onSurface,
      muted = Theme.of(context).colorScheme.onSurfaceVariant,
      faint = Color.lerp(
        Theme.of(context).colorScheme.onSurface,
        Theme.of(context).colorScheme.surface,
        .55,
      )!,
      accent = Theme.of(context).colorScheme.primary,
      accentInk = Theme.of(context).colorScheme.onPrimary,
      accentSoft = Color.alphaBlend(
        Theme.of(context).colorScheme.primary.withValues(alpha: .10),
        Theme.of(context).colorScheme.surface,
      ),
      running = AppStatusColors.of(context).running,
      runningSoft = AppStatusColors.of(context).runningSoft,
      confirmation = AppStatusColors.of(context).confirmation,
      confirmationSoft = AppStatusColors.of(context).confirmationSoft,
      success = AppStatusColors.of(context).completed,
      successSoft = AppStatusColors.of(context).completedSoft;
  static PrototypeColors of(BuildContext context) => PrototypeColors._(context);
  final Color surface,
      panel,
      line,
      ink,
      muted,
      faint,
      accent,
      accentInk,
      accentSoft,
      running,
      runningSoft,
      confirmation,
      confirmationSoft,
      success,
      successSoft;
}

enum PrototypeTone { neutral, accent, running, confirmation, success }

enum PrototypeButtonVariant { normal, primary, ghost, danger }

bool _phone(BuildContext context) => MediaQuery.sizeOf(context).width < 840;
TextStyle _label(
  BuildContext context,
  double size,
  Color color, [
  FontWeight weight = FontWeight.w400,
]) => Theme.of(context).textTheme.bodyMedium!.copyWith(
  fontSize: size,
  height: 1.3,
  fontWeight: weight,
  color: color,
);

/// Touch padding is transparent: small visual controls never become large pills.
Widget _target(
  BuildContext context,
  Widget visual,
  VoidCallback? onPressed, {
  String? tooltip,
  BorderRadius? radius,
  bool selected = false,
}) => _PrototypeTarget(
  visual: visual,
  onPressed: onPressed,
  tooltip: tooltip,
  radius: radius ?? BorderRadius.circular(8),
  selected: selected,
);

class _PrototypeTarget extends StatefulWidget {
  const _PrototypeTarget({
    required this.visual,
    required this.onPressed,
    required this.radius,
    required this.selected,
    this.tooltip,
  });
  final Widget visual;
  final VoidCallback? onPressed;
  final BorderRadius radius;
  final bool selected;
  final String? tooltip;
  @override
  State<_PrototypeTarget> createState() => _PrototypeTargetState();
}

class _PrototypeTargetState extends State<_PrototypeTarget> {
  bool _hover = false, _focus = false;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final enabled = widget.onPressed != null;
    final decorated = DecoratedBox(
      key: _focus && enabled
          ? const ValueKey('prototype-focus-outline')
          : _hover && enabled
          ? const ValueKey('prototype-hover-outline')
          : null,
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: widget.radius,
        border: _focus && enabled
            ? Border.all(color: c.accent, width: 2)
            : _hover && enabled
            ? Border.all(color: c.faint)
            : null,
      ),
      child: widget.visual,
    );
    Widget result = Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPressed,
          canRequestFocus: enabled,
          onHover: (v) {
            if (_hover != v) setState(() => _hover = v);
          },
          onFocusChange: (v) {
            if (_focus != v) setState(() => _focus = v);
          },
          borderRadius: widget.radius,
          child: ConstrainedBox(
            constraints: _phone(context)
                ? const BoxConstraints(minHeight: 44, minWidth: 44)
                : const BoxConstraints(),
            child: Center(widthFactor: 1, heightFactor: 1, child: decorated),
          ),
        ),
      ),
    );
    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      result = Tooltip(message: widget.tooltip!, child: result);
    }
    return result;
  }
}

class PrototypeButton extends StatelessWidget {
  const PrototypeButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.small = false,
    this.expand = false,
    this.variant = PrototypeButtonVariant.normal,
    this.tooltip,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool small, expand;
  final PrototypeButtonVariant variant;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final primary = variant == PrototypeButtonVariant.primary;
    final ghost = variant == PrototypeButtonVariant.ghost;
    final foreground = primary
        ? c.accentInk
        : variant == PrototypeButtonVariant.danger
        ? c.confirmation
        : ghost
        ? c.accent
        : c.ink;
    final visual = Opacity(
      opacity: onPressed == null ? .4 : 1,
      child: Container(
        constraints: BoxConstraints(minHeight: small ? 24 : 34),
        padding: EdgeInsets.symmetric(
          horizontal: small ? 9 : 14,
          vertical: small ? 3 : 7,
        ),
        decoration: BoxDecoration(
          color: primary
              ? c.accent
              : ghost
              ? Colors.transparent
              : c.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: primary || ghost ? Colors.transparent : c.line,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final text = Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _label(
                context,
                small ? 12 : 13,
                foreground,
                primary ? FontWeight.w500 : FontWeight.w400,
              ),
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: small ? 13 : 15, color: foreground),
                  const SizedBox(width: 6),
                ],
                if (constraints.hasBoundedWidth)
                  Flexible(child: text)
                else
                  text,
              ],
            );
          },
        ),
      ),
    );
    return _target(
      context,
      expand
          ? LayoutBuilder(
              builder: (context, constraints) => SizedBox(
                width: constraints.hasBoundedWidth
                    ? constraints.maxWidth
                    : null,
                child: visual,
              ),
            )
          : visual,
      onPressed,
      tooltip: tooltip ?? label,
    );
  }
}

class PrototypeChip extends StatelessWidget {
  const PrototypeChip({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.selected = false,
    this.tone = PrototypeTone.neutral,
    this.maxWidth,
    this.tooltip,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool selected;
  final PrototypeTone tone;
  final double? maxWidth;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final effective = selected && tone == PrototypeTone.neutral
        ? PrototypeTone.accent
        : tone;
    final (foreground, background) = switch (effective) {
      PrototypeTone.accent => (c.accent, c.accentSoft),
      PrototypeTone.running => (c.running, c.runningSoft),
      PrototypeTone.confirmation => (c.confirmation, c.confirmationSoft),
      PrototypeTone.success => (c.success, c.successSoft),
      _ => (c.muted, c.surface),
    };
    final visual = Container(
      constraints: BoxConstraints(
        minHeight: 26,
        maxWidth: maxWidth ?? double.infinity,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: effective == PrototypeTone.neutral
              ? c.line
              : Colors.transparent,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, size) {
          final text = Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _label(context, 12, foreground),
          );
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 13, color: foreground),
                const SizedBox(width: 6),
              ],
              if (size.hasBoundedWidth) Flexible(child: text) else text,
            ],
          );
        },
      ),
    );
    if (onPressed == null) return visual;
    return _target(
      context,
      visual,
      onPressed,
      tooltip: tooltip ?? label,
      radius: BorderRadius.circular(999),
      selected: selected,
    );
  }
}

class PrototypeIconButton extends StatelessWidget {
  const PrototypeIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.selected = false,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return _target(
      context,
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: selected ? c.panel : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: LineIcon(
          icon,
          size: 18,
          color: onPressed == null ? c.faint : c.muted,
        ),
      ),
      onPressed,
      tooltip: tooltip,
      radius: BorderRadius.circular(10),
      selected: selected,
    );
  }
}

class PrototypeTab<T> {
  const PrototypeTab({
    required this.value,
    required this.label,
    this.count,
    this.enabled = true,
    this.key,
  });
  final T value;
  final String label;
  final int? count;
  final bool enabled;
  final Key? key;
}

class PrototypeTabStrip<T> extends StatelessWidget {
  const PrototypeTabStrip({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
  });
  final List<PrototypeTab<T>> tabs;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.line)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final tab in tabs)
                  KeyedSubtree(
                    key: tab.key,
                    child: _target(
                      context,
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: tab.value == value
                                  ? c.ink
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tab.label,
                              style: _label(
                                context,
                                13,
                                tab.value == value ? c.ink : c.muted,
                                tab.value == value
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                            ),
                            if (tab.count != null) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${tab.count}',
                                style: _label(
                                  context,
                                  11,
                                  c.faint,
                                ).copyWith(fontFamily: 'monospace'),
                              ),
                            ],
                          ],
                        ),
                      ),
                      tab.enabled ? () => onChanged(tab.value) : null,
                      selected: tab.value == value,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PrototypeSegment<T> {
  const PrototypeSegment({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
  });
  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;
}

class PrototypeSegmentedControl<T> extends StatelessWidget {
  const PrototypeSegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });
  final List<PrototypeSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 3,
          vertical: _phone(context) ? 0 : 3,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final segment in segments)
              _target(
                context,
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: segment.value == value
                        ? c.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (segment.icon != null) ...[
                        Icon(segment.icon, size: 14, color: c.muted),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        segment.label,
                        style: _label(
                          context,
                          14,
                          segment.value == value ? c.ink : c.muted,
                          segment.value == value
                              ? FontWeight.w500
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
                segment.enabled && onChanged != null
                    ? () => onChanged!(segment.value)
                    : null,
                selected: segment.value == value,
              ),
          ],
        ),
      ),
    );
  }
}

class PrototypePanel extends StatelessWidget {
  const PrototypePanel({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    this.outlined = false,
    this.color,
  });
  final Widget child;
  final String? title, subtitle;
  final EdgeInsetsGeometry padding;
  final bool outlined;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return Material(
      color: color ?? (outlined ? c.surface : c.panel),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: outlined ? BorderSide(color: c.line) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title != null || subtitle != null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: _label(context, 14, c.ink, FontWeight.w500),
                    ),
                  if (subtitle != null)
                    Text(subtitle!, style: _label(context, 12, c.muted)),
                ],
              ),
              const SizedBox(height: 8),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class PrototypeSwitch extends StatelessWidget {
  const PrototypeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return Semantics(
      label: semanticLabel,
      toggled: value,
      enabled: onChanged != null,
      child: _target(
        context,
        Container(
          width: 34,
          height: 20,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: value ? c.success : c.line,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Align(
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: c.surface,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        onChanged == null ? null : () => onChanged!(!value),
        radius: BorderRadius.circular(999),
      ),
    );
  }
}
