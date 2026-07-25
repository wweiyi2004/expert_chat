/// One HTML document extracted from assistant markdown (or raw HTML).
class HtmlSnippet {
  const HtmlSnippet({required this.html, required this.language, this.title});

  /// Full HTML string suitable for WebView / browser preview.
  final String html;

  /// Fence language label (html / htm / empty).
  final String language;

  /// Best-effort page title from `<title>` if present.
  final String? title;
}

/// Extracts previewable HTML from model output.
///
/// Supports:
/// - fenced blocks: ```html … ```, ```htm … ```
/// - bare full documents: `<!DOCTYPE html>` / `<html>…</html>`
/// - fenced ``` without language when body looks like HTML
List<HtmlSnippet> extractHtmlSnippets(String content) {
  final text = content.trim();
  if (text.isEmpty) return const [];

  final out = <HtmlSnippet>[];
  final seen = <String>{};

  // ```lang\n...\n```  (lang optional)
  final fence = RegExp(r'```([^\n`]*)\n([\s\S]*?)```', multiLine: true);
  for (final m in fence.allMatches(text)) {
    final lang = (m.group(1) ?? '').trim().toLowerCase();
    final body = (m.group(2) ?? '').trim();
    if (body.isEmpty) continue;
    final isHtmlLang =
        lang == 'html' ||
        lang == 'htm' ||
        lang == 'xhtml' ||
        lang.startsWith('html');
    final isUntitledHtml = lang.isEmpty && _looksLikeHtml(body);
    if (!isHtmlLang && !isUntitledHtml) continue;
    final html = _normalizeToDocument(body);
    if (!_looksLikeHtml(html)) continue;
    if (!seen.add(html)) continue;
    out.add(
      HtmlSnippet(
        html: html,
        language: lang.isEmpty ? 'html' : lang,
        title: _extractTitle(html),
      ),
    );
  }

  // Bare full document outside fences.
  if (out.isEmpty && _looksLikeFullDocument(text)) {
    final html = _normalizeToDocument(text);
    out.add(
      HtmlSnippet(html: html, language: 'html', title: _extractTitle(html)),
    );
  }

  return out;
}

bool messageHasHtmlPreview(String content) =>
    extractHtmlSnippets(content).isNotEmpty;

bool _looksLikeFullDocument(String s) {
  final lower = s.toLowerCase();
  return lower.contains('<!doctype html') ||
      (lower.contains('<html') && lower.contains('</html>'));
}

bool _looksLikeHtml(String s) {
  final lower = s.toLowerCase().trimLeft();
  if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
    return true;
  }
  // Fragment with structure tags common in generated pages.
  const tags = [
    '<div',
    '<body',
    '<head',
    '<section',
    '<main',
    '<header',
    '<style',
    '<script',
    '<button',
    '<nav',
  ];
  var hits = 0;
  for (final t in tags) {
    if (lower.contains(t)) hits++;
  }
  return hits >= 2 || (lower.contains('<') && lower.contains('</'));
}

String _normalizeToDocument(String raw) {
  final body = raw.trim();
  final lower = body.toLowerCase();
  if (lower.contains('<html') || lower.startsWith('<!doctype')) {
    return body;
  }
  // Wrap fragments so CSS/JS behave more predictably in WebView.
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>预览</title>
<style>
  html,body{margin:0;padding:0;font-family:system-ui,-apple-system,sans-serif;}
</style>
</head>
<body>
$body
</body>
</html>
''';
}

String? _extractTitle(String html) {
  final m = RegExp(
    r'<title[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(html);
  final t = m?.group(1)?.trim();
  if (t == null || t.isEmpty) return null;
  return t.length > 40 ? '${t.substring(0, 40)}…' : t;
}
