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
  final headEnd = _firstTagOutsideMarkup(source, 'head');
  if (headEnd != null) {
    return source.replaceRange(headEnd, headEnd, policy);
  }

  final rootEnd = _firstTagOutsideMarkup(source, 'html');
  if (rootEnd != null) {
    return source.replaceRange(rootEnd, rootEnd, '<head>$policy</head>');
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

/// End of the first opening `<name ...>` start tag that sits in genuine
/// markup context: the position right after its closing `>`, or null if there
/// is none. A single linear scan tracks the contexts in which `<head>` /
/// `<html>` text must not be trusted as a real element — HTML comments,
/// script and style element content (including string literals), and tag
/// attribute values. A policy meta injected into any of those would be inert
/// text instead of an active CSP, leaving the document unprotected.
int? _firstTagOutsideMarkup(String source, String name) {
  var i = 0;
  final n = source.length;
  while (i < n) {
    if (source.codeUnitAt(i) != 0x3C /* < */ ) {
      i++;
      continue;
    }
    if (i + 1 >= n) break;
    final next = source.codeUnitAt(i + 1);
    if (next == 0x21 /* ! */ ) {
      if (i + 3 < n &&
          source.codeUnitAt(i + 2) == 0x2D && // -
          source.codeUnitAt(i + 3) == 0x2D) {
        // HTML comment: `-->` ends it; an unterminated one swallows the rest.
        final close = source.indexOf('-->', i + 4);
        i = close < 0 ? n : close + 3;
      } else {
        // Doctype / bogus comment: opaque until its closing `>`.
        i = _skipTag(source, i);
      }
      continue;
    }
    if (next == 0x3F /* ? */ ) {
      // Processing instruction / bogus comment: opaque until its `>`.
      i = _skipTag(source, i);
      continue;
    }
    if (next == 0x2F /* / */ ) {
      // Closing tag: nothing of interest inside.
      i = _skipTag(source, i);
      continue;
    }
    if (!_isAsciiLetter(next)) {
      i++; // bare '<' in text, not markup
      continue;
    }
    if (_isStartTagAt(source, i, name)) {
      return _skipTag(source, i);
    }
    final isScript = _isStartTagAt(source, i, 'script');
    final isStyle = _isStartTagAt(source, i, 'style');
    if (isScript || isStyle) {
      // Raw-text element: skip its content until the matching close tag.
      i = _skipRawTextContent(
        source,
        _skipTag(source, i),
        isScript ? _scriptEndTag : _styleEndTag,
      );
      continue;
    }
    // Ordinary element: only its attribute values are opaque.
    i = _skipTag(source, i);
  }
  return null;
}

/// End of the tag starting at [i]: the position after its closing `>`,
/// honouring quoted attribute values so a `>` inside quotes does not end the
/// tag.
int _skipTag(String source, int i) {
  final n = source.length;
  var quote = -1;
  while (i < n) {
    final c = source.codeUnitAt(i);
    if (quote >= 0) {
      if (c == quote) quote = -1;
    } else if (c == 0x22 || c == 0x27) {
      // " '
      quote = c;
    } else if (c == 0x3E /* > */ ) {
      return i + 1;
    }
    i++;
  }
  return n;
}

/// End of the raw-text content of a script/style element whose start tag ends
/// at [contentStart]: the position after the matching close tag, or end of
/// input when it is missing. A `</scriptx>` does not close the element, which
/// mirrors browser tokenizer behaviour.
int _skipRawTextContent(String source, int contentStart, RegExp closeTag) {
  var from = contentStart;
  while (true) {
    final match = _firstMatchFrom(closeTag, source, from);
    if (match == null) return source.length;
    final boundary = match.end < source.length
        ? source.codeUnitAt(match.end)
        : -1;
    if (boundary == 0x3E /* > */ ||
        boundary == 0x09 ||
        boundary == 0x0A ||
        boundary == 0x0C ||
        boundary == 0x0D ||
        boundary == 0x20 ||
        boundary < 0) {
      return _skipTag(source, match.start);
    }
    from = match.end;
  }
}

/// Whether `<name` (ASCII case-insensitive) starts a real tag at [i]: the
/// character after the name must be a tag boundary (`>`, `/` or whitespace).
bool _isStartTagAt(String source, int i, String name) {
  final n = source.length;
  if (i + 1 + name.length >= n) return false;
  for (var k = 0; k < name.length; k++) {
    if (!_eqAsciiFold(source.codeUnitAt(i + 1 + k), name.codeUnitAt(k))) {
      return false;
    }
  }
  final boundary = source.codeUnitAt(i + 1 + name.length);
  return boundary == 0x3E ||
      boundary == 0x2F ||
      boundary == 0x09 ||
      boundary == 0x0A ||
      boundary == 0x0C ||
      boundary == 0x0D ||
      boundary == 0x20;
}

final _scriptEndTag = RegExp(r'</script', caseSensitive: false);
final _styleEndTag = RegExp(r'</style', caseSensitive: false);

/// First match of [pattern] in [source] at or after [from], or null. The
/// match is produced lazily so scanning a long document never materialises a
/// full match list.
RegExpMatch? _firstMatchFrom(RegExp pattern, String source, int from) {
  final iterator = pattern.allMatches(source, from).iterator;
  return iterator.moveNext() ? iterator.current : null;
}

bool _eqAsciiFold(int a, int b) => a == b || (a | 0x20) == (b | 0x20);

bool _isAsciiLetter(int c) {
  final lower = c | 0x20;
  return lower >= 0x61 && lower <= 0x7A;
}

String _escapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
