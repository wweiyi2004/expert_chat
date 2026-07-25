/// Network policy used by generated-page previews.
///
/// Inline CSS and JavaScript remain available for interactive mockups, while
/// remote resources, fetch/WebSocket calls, forms, frames, workers and plugins
/// are blocked. Navigation is also denied by the host WebView.
const htmlPreviewContentSecurityPolicy =
    "default-src 'none'; "
    "base-uri 'none'; "
    "connect-src 'none'; "
    "font-src data:; "
    "form-action 'none'; "
    "frame-src 'none'; "
    "img-src data: blob:; "
    "media-src data: blob:; "
    "object-src 'none'; "
    "script-src 'unsafe-inline'; "
    "style-src 'unsafe-inline'; "
    "worker-src 'none'";

/// Wraps untrusted generated HTML in a sandboxed, full-viewport `srcdoc` frame.
///
/// The iframe deliberately omits `allow-same-origin`, `allow-forms`,
/// `allow-popups`, downloads and top navigation. The inner CSP is injected at
/// the start of `<head>` so content cannot load remote dependencies before the
/// policy is active.
String buildSandboxedHtmlPreview(String html) {
  final protected = _injectPreviewPolicy(html);
  final srcdoc = _escapeAttribute(protected);
  final frameCsp = _escapeAttribute(htmlPreviewContentSecurityPolicy);
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<meta http-equiv="Content-Security-Policy"
      content="default-src 'none'; frame-src 'self'; style-src 'unsafe-inline'"/>
<meta http-equiv="x-dns-prefetch-control" content="off"/>
<style>
  html,body{width:100%;height:100%;margin:0;padding:0;overflow:hidden;}
  iframe{display:block;width:100%;height:100%;border:0;background:white;}
</style>
</head>
<body>
<iframe
  title="HTML preview"
  sandbox="allow-scripts"
  referrerpolicy="no-referrer"
  csp="$frameCsp"
  srcdoc="$srcdoc"></iframe>
</body>
</html>
''';
}

String _injectPreviewPolicy(String html) {
  const policy =
      '''
<meta http-equiv="Content-Security-Policy"
      content="$htmlPreviewContentSecurityPolicy"/>
<meta http-equiv="x-dns-prefetch-control" content="off"/>
<meta name="referrer" content="no-referrer"/>
''';
  final source = html.trim();
  final head = RegExp(
    r'<head(?:\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(source);
  if (head != null) {
    return source.replaceRange(head.end, head.end, policy);
  }

  final root = RegExp(
    r'<html(?:\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(source);
  if (root != null) {
    return source.replaceRange(root.end, root.end, '<head>$policy</head>');
  }

  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
$policy
</head>
<body>
$source
</body>
</html>
''';
}

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
