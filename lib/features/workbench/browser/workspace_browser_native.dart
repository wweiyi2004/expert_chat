import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart' as windows;
import '../../../domain/html/windows_webview_environment.dart';

class WorkspaceBrowserPanel extends StatefulWidget {
  const WorkspaceBrowserPanel({super.key});
  @override
  State<WorkspaceBrowserPanel> createState() => _WorkspaceBrowserPanelState();
}

class _WorkspaceBrowserPanelState extends State<WorkspaceBrowserPanel> {
  final _address = TextEditingController();
  final _focus = FocusNode();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  windows.WebviewController? _windows;
  WebViewController? _mobile;
  bool _ready = false, _loading = false, _hasPage = false;
  String? _error;
  String _url = '';
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    windows.WebviewController? pending;
    var initialized = false;
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await ensureWindowsWebviewEnvironment();
        if (!mounted) return;
        pending = windows.WebviewController();
        await pending.initialize();
        initialized = true;
        await pending.setPopupWindowPolicy(
          windows.WebviewPopupWindowPolicy.deny,
        );
        if (!mounted) {
          await pending.dispose();
          return;
        }
        _windows = pending;
        _subscriptions.add(pending.url.listen(_navigated));
        _subscriptions.add(
          pending.loadingState.listen((state) {
            if (mounted)
              setState(() => _loading = state == windows.LoadingState.loading);
          }),
        );
        _subscriptions.add(
          pending.onLoadError.listen((_) {
            if (mounted)
              setState(() {
                _loading = false;
                _error = '页面未能加载，可以重试或在外部浏览器打开。';
              });
          }),
        );
      } else if ([
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ].contains(defaultTargetPlatform)) {
        final controller = WebViewController();
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) => _valid(request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
            onPageStarted: (url) {
              _navigated(url);
              if (mounted) setState(() => _loading = true);
            },
            onPageFinished: (_) {
              if (mounted) setState(() => _loading = false);
            },
            onWebResourceError: (error) {
              if (mounted && error.isForMainFrame == true)
                setState(() {
                  _loading = false;
                  _error = error.description;
                });
            },
          ),
        );
        if (!mounted) return;
        _mobile = controller;
      } else {
        throw UnsupportedError('此平台请使用外部浏览器打开网址。');
      }
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (pending != null && initialized && _windows == null)
        await pending.dispose();
      if (mounted) setState(() => _error = '$error');
    }
  }

  bool _valid(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty;
  }

  void _navigated(String url) {
    if (!mounted || !_valid(url)) return;
    _url = url;
    if (!_focus.hasFocus) _address.text = url;
  }

  String _normalized() {
    final raw = _address.text.trim();
    if (raw.contains('://')) return raw;
    return raw.startsWith('localhost') ||
            raw.startsWith('127.0.0.1') ||
            raw.startsWith('[::1]')
        ? 'http://$raw'
        : 'https://$raw';
  }

  Future<void> _navigate() async {
    final url = _normalized();
    if (!_valid(url)) {
      setState(() => _error = '请输入 HTTP 或 HTTPS 地址');
      return;
    }
    _focus.unfocus();
    setState(() {
      _error = null;
      _hasPage = true;
      _loading = true;
      _url = url;
      _address.text = url;
    });
    try {
      if (_windows != null) {
        await _windows!.loadUrl(url);
      } else if (_mobile != null) {
        await _mobile!.loadRequest(Uri.parse(url));
      }
    } catch (error) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = '$error';
        });
    }
  }

  Future<void> _action(String action) async {
    try {
      if (_windows != null) {
        switch (action) {
          case 'back':
            await _windows!.goBack();
          case 'forward':
            await _windows!.goForward();
          case 'reload':
            await _windows!.reload();
        }
      } else if (_mobile != null) {
        switch (action) {
          case 'back':
            if (await _mobile!.canGoBack()) await _mobile!.goBack();
          case 'forward':
            if (await _mobile!.canGoForward()) await _mobile!.goForward();
          case 'reload':
            await _mobile!.reload();
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _windows?.dispose();
    _address.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: '后退',
              onPressed: _hasPage ? () => _action('back') : null,
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            IconButton(
              tooltip: '前进',
              onPressed: _hasPage ? () => _action('forward') : null,
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
            IconButton(
              tooltip: '刷新网页',
              onPressed: _hasPage
                  ? () {
                      setState(() => _error = null);
                      _action('reload');
                    }
                  : null,
              icon: const Icon(Icons.refresh, size: 20),
            ),
            Expanded(
              child: TextField(
                controller: _address,
                focusNode: _focus,
                onSubmitted: (_) => _ready ? _navigate() : null,
                style: Theme.of(context).textTheme.bodySmall,
                decoration: InputDecoration(
                  hintText: '输入 HTTP(S) 地址',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  suffixIcon: IconButton(
                    tooltip: '打开网址',
                    onPressed: _ready ? _navigate : null,
                    icon: const Icon(Icons.arrow_forward, size: 17),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '外部浏览器打开',
              onPressed: () async {
                final url = _url.isEmpty ? _normalized() : _url;
                if (_valid(url))
                  await launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  );
              },
              icon: const Icon(Icons.north_east, size: 19),
            ),
          ],
        ),
      ),
      if (_loading) const LinearProgressIndicator(minHeight: 2),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: !_ready && _error == null
            ? const Center(child: CircularProgressIndicator())
            : !_hasPage
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('输入 HTTP(S) 地址开始浏览', textAlign: TextAlign.center),
                ),
              )
            : _windows != null
            ? windows.Webview(
                _windows!,
                permissionRequested: (_, _, _) =>
                    windows.WebviewPermissionDecision.deny,
              )
            : _mobile != null
            ? WebViewWidget(controller: _mobile!)
            : const SizedBox.shrink(),
      ),
    ],
  );
}
