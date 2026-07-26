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

/// Policy for the host document which owns the `srcdoc` iframe.
///
/// CSP is inherited by `srcdoc` documents, so this policy must permit the
/// capabilities intentionally allowed by [htmlPreviewContentSecurityPolicy].
/// The host itself contains no untrusted executable markup; generated HTML is
/// attribute-escaped into the sandboxed iframe below.
const htmlPreviewHostContentSecurityPolicy =
    "default-src 'none'; "
    "base-uri 'none'; "
    "connect-src 'none'; "
    "font-src data:; "
    "form-action 'none'; "
    "frame-src 'self'; "
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
  final hostCsp = _escapeAttribute(htmlPreviewHostContentSecurityPolicy);
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<meta http-equiv="Content-Security-Policy"
      content="$hostCsp"/>
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
  final head = _firstMatchOutsideComments(
    source,
    RegExp(r'<head(?:\s[^>]*)?>', caseSensitive: false),
  );
  if (head != null) {
    return source.replaceRange(head.end, head.end, policy);
  }

  final root = _firstMatchOutsideComments(
    source,
    RegExp(r'<html(?:\s[^>]*)?>', caseSensitive: false),
  );
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

/// First match of [pattern] that is not inside an HTML comment. Generated
/// markup routinely contains commented-out tags (`<!-- <head> -->`); a policy
/// injected there would be inert text instead of an active CSP.
RegExpMatch? _firstMatchOutsideComments(String source, RegExp pattern) {
  final comments = <(int, int)>[
    for (final c in RegExp(r'<!--.*?-->', dotAll: true).allMatches(source))
      (c.start, c.end),
  ];
  // An unterminated `<!--` swallows everything after it.
  final lastOpen = source.lastIndexOf('<!--');
  if (lastOpen >= 0 && !comments.any((r) => r.$1 == lastOpen)) {
    comments.add((lastOpen, source.length));
  }
  for (final m in pattern.allMatches(source)) {
    final inComment = comments.any((r) => m.start >= r.$1 && m.start < r.$2);
    if (!inComment) return m;
  }
  return null;
}

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
