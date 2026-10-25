import 'dart:async';
import 'package:flutter/material.dart';

/// A large application-owned window. Its navigator keeps editors and their
/// save guards inside the same surface instead of replacing the conversation.
class ApplicationSurface extends StatefulWidget {
  const ApplicationSurface({
    super.key,
    required this.child,
    required this.title,
    required this.onClose,
    this.active = true,
    this.header,
    this.protectRoot = true,
  });
  final Widget child;
  final String title;
  final FutureOr<void> Function() onClose;
  final bool active;
  final Widget? header;
  final bool protectRoot;
  static final List<_ApplicationSurfaceState> _surfaces = [];
  static bool get hasActive =>
      _surfaces.any((surface) => surface.mounted && surface.widget.active);
  static Future<bool> closeActive() async {
    for (final surface in _surfaces.reversed.toList()) {
      if (surface.mounted && surface.widget.active) return surface._close();
    }
    return true;
  }

  @override
  State<ApplicationSurface> createState() => _ApplicationSurfaceState();
}

class _ApplicationSurfaceState extends State<ApplicationSurface> {
  final _navigator = GlobalKey<NavigatorState>();
  final _observer = _SurfaceObserver();
  @override
  void initState() {
    super.initState();
    ApplicationSurface._surfaces.add(this);
  }

  @override
  void dispose() {
    ApplicationSurface._surfaces.remove(this);
    super.dispose();
  }

  Future<bool> _close() async {
    final navigator = _navigator.currentState;
    if (navigator == null) return false;
    // Respect unsaved editor PopScopes rather than forcing the stack away.
    while (navigator.canPop()) {
      final depth = _observer.depth;
      if (!await navigator.maybePop()) return false;
      if (!mounted) return false;
      await WidgetsBinding.instance.endOfFrame;
      if (_observer.depth >= depth) return false;
    }
    if (widget.protectRoot &&
        _observer.top?.popDisposition == RoutePopDisposition.doNotPop) {
      await navigator.maybePop();
      return false;
    }
    await widget.onClose();
    return true;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280, maxHeight: 1000),
        child: Material(
          key: const ValueKey('application-surface'),
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.outline.withValues(alpha: .35),
            ),
          ),
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Row(
                  children: [
                    const SizedBox(width: 20),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.header != null) Flexible(child: widget.header!),
                    IconButton(
                      tooltip: '关闭窗口',
                      onPressed: _close,
                      icon: const Icon(Icons.close, size: 20),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Navigator(
                  key: _navigator,
                  observers: [_observer],
                  pages: [MaterialPage<void>(child: widget.child)],
                  onDidRemovePage: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Route<T> applicationSurfaceRoute<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
  String title = '设置',
  bool protectRoot = true,
}) {
  if (MediaQuery.sizeOf(context).width < 840) {
    return MaterialPageRoute<T>(settings: settings, builder: builder);
  }
  return PageRouteBuilder<T>(
    settings: settings,
    opaque: false,
    barrierDismissible: false,
    barrierColor: Colors.black38,
    pageBuilder: (context, animation, secondaryAnimation) => ApplicationSurface(
      title: title,
      protectRoot: protectRoot,
      onClose: () async {
        await Navigator.of(context).maybePop();
      },
      child: Builder(builder: builder),
    ),
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _SurfaceObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];
  int get depth => _routes.length;
  Route<dynamic>? get top => _routes.lastOrNull;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }
}
