import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/runtime/embedded_runtime.dart';
import '../domain/notify/generation_notify.dart';

/// Connects Flutter lifecycle to the app-owned execution runtime. Backgrounding
/// keeps tasks alive; only detaching the application releases the runtime.
class EmbeddedRuntimeScope extends StatefulWidget {
  const EmbeddedRuntimeScope({
    super.key,
    required this.runtime,
    required this.child,
  });
  final EmbeddedRuntime runtime;
  final Widget child;

  static EmbeddedRuntime? maybeOf(BuildContext context) =>
      context.findAncestorWidgetOfExactType<EmbeddedRuntimeScope>()?.runtime;

  @override
  State<EmbeddedRuntimeScope> createState() => _EmbeddedRuntimeScopeState();
}

class _EmbeddedRuntimeScopeState extends State<EmbeddedRuntimeScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached;
    GenerationNotify.setAppBackground(background);
    widget.runtime.reportBackground(background);
    if (state == AppLifecycleState.detached) unawaited(widget.runtime.close());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.runtime.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: widget.runtime.container,
    child: widget.child,
  );
}
