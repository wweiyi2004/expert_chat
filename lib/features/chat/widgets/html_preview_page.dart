import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../domain/html/html_preview_sandbox.dart';
import '../../../domain/html/html_snippet.dart';
import 'html_preview_launcher_web.dart'
    if (dart.library.io) 'html_preview_launcher_io.dart';

/// Full-screen (or desktop) preview of AI-generated HTML.
///
/// Mobile / platforms with WebView: in-app [WebView].
/// Desktop fallback: write a temp file and open the system browser.
class HtmlPreviewPage extends StatefulWidget {
  const HtmlPreviewPage({
    super.key,
    required this.snippets,
    this.initialIndex = 0,
  });

  final List<HtmlSnippet> snippets;
  final int initialIndex;

  static Future<void> open(
    BuildContext context, {
    required List<HtmlSnippet> snippets,
    int initialIndex = 0,
  }) {
    if (snippets.isEmpty) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            HtmlPreviewPage(snippets: snippets, initialIndex: initialIndex),
      ),
    );
  }

  @override
  State<HtmlPreviewPage> createState() => _HtmlPreviewPageState();
}

class _HtmlPreviewPageState extends State<HtmlPreviewPage> {
  static const _previewBaseUrl = 'https://preview.invalid/';

  late int _index;
  WebViewController? _controller;
  var _useWebView = false;
  var _loading = true;
  String? _error;

  HtmlSnippet get _current => widget.snippets[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.snippets.length - 1);
    _initPreview();
  }

  Future<void> _initPreview() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // Prefer in-app WebView on mobile; desktop often lacks a stable plugin.
    final mobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);

    // Browsers require opening a new tab from a direct user gesture. Keep the
    // route visible and let the button below invoke the blob-URL launcher.
    if (kIsWeb) {
      if (!mounted) return;
      setState(() {
        _useWebView = false;
        _loading = false;
      });
      return;
    }

    if (mobile) {
      try {
        final c = WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..setBackgroundColor(const Color(0x00000000))
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (_) {
                if (mounted) setState(() => _loading = false);
              },
              onWebResourceError: (e) {
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _error = e.description;
                  });
                }
              },
              // The generated page lives in a sandboxed iframe. Keep the host
              // document local as a second boundary: never launch or navigate
              // to a URL requested by untrusted page JavaScript.
              onNavigationRequest: (req) {
                final u = req.url;
                if (u == _previewBaseUrl ||
                    u.startsWith('$_previewBaseUrl#') ||
                    u == 'about:blank' ||
                    u.startsWith('about:blank#')) {
                  return NavigationDecision.navigate;
                }
                return NavigationDecision.prevent;
              },
            ),
          );
        await c.loadHtmlString(
          buildSandboxedHtmlPreview(_current.html),
          baseUrl: _previewBaseUrl,
        );
        if (!mounted) return;
        setState(() {
          _controller = c;
          _useWebView = true;
          _loading = false;
        });
        return;
      } catch (e) {
        // Fall through to external browser.
        _error = e.toString();
      }
    }

    await _openInExternalBrowser();
    if (mounted) {
      setState(() {
        _useWebView = false;
        _loading = false;
      });
    }
  }

  Future<void> _openInExternalBrowser() async {
    try {
      await launchHtmlPreview(
        buildSandboxedHtmlPreview(_current.html),
        fileName: 'expert_chat_preview_$_index.html',
      );
    } catch (e) {
      // StateError.toString() prefixes "Bad state:"; show the message alone.
      final message = e is StateError ? e.message : '$e';
      if (mounted) setState(() => _error = '预览失败：$message');
    }
  }

  Future<void> _reloadSnippet() async {
    if (_useWebView && _controller != null) {
      setState(() => _loading = true);
      await _controller!.loadHtmlString(
        buildSandboxedHtmlPreview(_current.html),
        baseUrl: _previewBaseUrl,
      );
      if (mounted) setState(() => _loading = false);
    } else {
      await _openInExternalBrowser();
    }
  }

  Future<void> _copyHtml() async {
    await Clipboard.setData(ClipboardData(text: _current.html));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制 HTML'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _current.title ?? '网页预览';
    final multi = widget.snippets.length > 1;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, overflow: TextOverflow.ellipsis),
            if (multi)
              Text(
                '${_index + 1} / ${widget.snippets.length}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
        actions: [
          if (multi) ...[
            IconButton(
              tooltip: '上一页',
              onPressed: _index <= 0
                  ? null
                  : () {
                      setState(() => _index--);
                      _initPreview();
                    },
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: '下一页',
              onPressed: _index >= widget.snippets.length - 1
                  ? null
                  : () {
                      setState(() => _index++);
                      _initPreview();
                    },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
          IconButton(
            tooltip: '复制 HTML',
            onPressed: _copyHtml,
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: _useWebView ? '刷新' : '在浏览器打开',
            onPressed: _reloadSnippet,
            icon: Icon(_useWebView ? Icons.refresh : Icons.open_in_browser),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_useWebView && _controller != null)
            WebViewWidget(controller: _controller!)
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.language,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error == null
                          ? kIsWeb
                                ? '点击下方按钮，在新标签页中打开安全预览'
                                : '已在系统浏览器中打开预览'
                          : _error!,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _openInExternalBrowser,
                      icon: const Icon(Icons.open_in_browser),
                      label: const Text('再次打开浏览器'),
                    ),
                  ],
                ),
              ),
            ),
          if (_loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
