import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../domain/html/windows_webview_environment.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as windows;

/// One immutable render session. The owner replaces its key to refresh content.
class LocalHtmlSurface extends StatefulWidget {
  const LocalHtmlSurface({super.key, required this.document});
  final String document;

  @override
  State<LocalHtmlSurface> createState() => _LocalHtmlSurfaceState();
}

class _LocalHtmlSurfaceState extends State<LocalHtmlSurface> {
  windows.WebviewController? _windows;
  WebViewController? _mobile;
  StreamSubscription<windows.WebErrorStatus>? _loadErrors;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    windows.WebviewController? pending;
    var initialized = false;
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        await ensureWindowsWebviewEnvironment();
        if (!mounted) return;
        pending = windows.WebviewController();
        await pending.initialize();
        initialized = true;
        await pending.setBackgroundColor(Colors.white);
        await pending.setPopupWindowPolicy(
          windows.WebviewPopupWindowPolicy.deny,
        );
        await pending.loadStringContent(widget.document);
        if (!mounted) return;
        final controller = pending;
        _loadErrors = controller.onLoadError.listen((_) {
          if (mounted) setState(() => _error = '页面加载失败，请刷新预览。');
        });
        setState(() => _windows = controller);
        pending =
            null; // Ownership passes to dispose only after initialization.
      } else if (!kIsWeb &&
          const [
            TargetPlatform.android,
            TargetPlatform.iOS,
            TargetPlatform.macOS,
          ].contains(defaultTargetPlatform)) {
        const baseUrl = 'https://preview.invalid/';
        final controller = WebViewController();
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.setBackgroundColor(Colors.white);
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) =>
                request.url == baseUrl ||
                    request.url.startsWith('$baseUrl#') ||
                    request.url == 'about:blank' ||
                    request.url == 'about:srcdoc' ||
                    request.url.startsWith('about:blank#')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onWebResourceError: (error) {
              if (mounted && error.isForMainFrame != false) {
                setState(() => _error = '页面加载失败，请刷新预览。');
              }
            },
          ),
        );
        if (!mounted) return;
        await controller.loadHtmlString(widget.document, baseUrl: baseUrl);
        if (mounted) setState(() => _mobile = controller);
      } else {
        if (mounted) setState(() => _error = '可使用右上角的浏览器按钮打开本地预览。');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StateError
              ? error.message
              : '内嵌预览暂时不可用，可刷新重试或在浏览器中打开。',
        );
      }
    } finally {
      if (initialized && pending != null) await _release(pending);
    }
  }

  Future<void> _release(windows.WebviewController controller) async {
    try {
      await controller.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_loadErrors?.cancel());
    final controller = _windows;
    if (controller != null) unawaited(_release(controller));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }
    if (_windows != null) {
      return windows.Webview(
        _windows!,
        permissionRequested: (_, _, _) =>
            windows.WebviewPermissionDecision.deny,
      );
    }
    if (_mobile != null) return WebViewWidget(controller: _mobile!);
    return const Center(child: CircularProgressIndicator());
  }
}
