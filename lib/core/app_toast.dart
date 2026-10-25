import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Lightweight feedback lives above routes without moving the page. Actions
/// and deliberately persistent progress messages keep their existing lifetime.
class AppToastMessenger {
  AppToastMessenger._(this._overlay);
  final OverlayState _overlay;
  static final _instances = Expando<AppToastMessenger>();
  OverlayEntry? _entry;
  Timer? _timer;
  Completer<SnackBarClosedReason>? _completion;

  static AppToastMessenger? maybeOf(BuildContext context) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return null;
    return _instances[overlay] ??= AppToastMessenger._(overlay);
  }

  static AppToastMessenger of(BuildContext context) => maybeOf(context)!;

  AppToastController showSnackBar(SnackBar snackBar) {
    hideCurrentSnackBar();
    final completion = Completer<SnackBarClosedReason>();
    _completion = completion;
    if (!_overlay.mounted) {
      completion.complete(SnackBarClosedReason.remove);
      return AppToastController._(completion.future, () {});
    }
    final requested = snackBar.duration == const Duration(milliseconds: 4000)
        ? const Duration(seconds: 2)
        : snackBar.duration;
    final duration = snackBar.action != null && requested.inSeconds < 8
        ? const Duration(seconds: 8)
        : requested;
    void close([SnackBarClosedReason reason = SnackBarClosedReason.dismiss]) {
      if (identical(_completion, completion)) {
        hideCurrentSnackBar(reason: reason);
      }
    }

    _entry = OverlayEntry(
      builder: (context) => _ToastLifetime(
        onMount: () {
          if (identical(_completion, completion)) {
            _timer = Timer(duration, () => close(SnackBarClosedReason.timeout));
          }
        },
        onUnmount: () {
          if (!identical(_completion, completion)) return;
          _timer?.cancel();
          _timer = null;
          _completion = null;
          final entry = _entry;
          _entry = null;
          if (!completion.isCompleted) {
            completion.complete(SnackBarClosedReason.remove);
          }
          // An enclosing Navigator can be torn down without an explicit hide.
          // Release after the overlay's unmount rather than dirtying it mid-build.
          if (entry != null) {
            scheduleMicrotask(() {
              entry.remove();
              entry.dispose();
            });
          }
        },
        child: _ToastCard(snackBar: snackBar, close: close),
      ),
    );
    _overlay.insert(_entry!);
    return AppToastController._(completion.future, close);
  }

  void hideCurrentSnackBar({
    SnackBarClosedReason reason = SnackBarClosedReason.hide,
  }) {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) {
      completion.complete(reason);
    }
  }

  void clearSnackBars() => hideCurrentSnackBar();
  void removeCurrentSnackBar() =>
      hideCurrentSnackBar(reason: SnackBarClosedReason.remove);
}

class _ToastLifetime extends StatefulWidget {
  const _ToastLifetime({
    required this.onMount,
    required this.onUnmount,
    required this.child,
  });
  final VoidCallback onMount, onUnmount;
  final Widget child;
  @override
  State<_ToastLifetime> createState() => _ToastLifetimeState();
}

class _ToastLifetimeState extends State<_ToastLifetime> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    widget.onUnmount();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AppToastController {
  AppToastController._(this.closed, this.close);
  final Future<SnackBarClosedReason> closed;
  final VoidCallback close;
}

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.snackBar, required this.close});
  final SnackBar snackBar;
  final void Function([SnackBarClosedReason reason]) close;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    final width = math.min(
      380.0,
      math.max(0.0, mq.size.width - 32 - mq.padding.horizontal),
    );
    return Positioned(
      right: 16 + mq.padding.right,
      // Leave the composer/send/recording action row reachable while feedback is shown.
      bottom: 96 + math.max(mq.padding.bottom, mq.viewInsets.bottom),
      width: width,
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Material(
          key: const ValueKey('app-toast'),
          color: colors.surfaceContainerHigh,
          shadowColor: colors.shadow.withValues(alpha: .18),
          elevation: 5,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.only(
              left: 14,
              top: 6,
              bottom: 6,
              right: 4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: colors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: mq.size.height * .3),
                    child: SingleChildScrollView(
                      child: DefaultTextStyle(
                        style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                          color: colors.onSurface,
                          height: 1.45,
                        ),
                        child: snackBar.content,
                      ),
                    ),
                  ),
                ),
                if (snackBar.action case final action?)
                  TextButton(
                    onPressed: () {
                      close(SnackBarClosedReason.action);
                      action.onPressed();
                    },
                    child: Text(action.label),
                  ),
                IconButton(
                  tooltip: '关闭提示',
                  onPressed: close,
                  icon: const Icon(Icons.close, size: 18),
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
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
