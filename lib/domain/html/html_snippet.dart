import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

enum HtmlPreviewKind { html, svg }

/// Renderable markup plus its original, editable source.
class HtmlSnippet {
  const HtmlSnippet({
    required this.html,
    required this.language,
    this.title,
    this.source,
    this.kind = HtmlPreviewKind.html,
  });

  final String html;
  final String language;
  final String? title;
  final String? source;
  final HtmlPreviewKind kind;
  String get code => source ?? html;
  String get extension => kind == HtmlPreviewKind.svg ? 'svg' : 'html';
  String get label => extension.toUpperCase();
}

/// Recognizes a single HTML/SVG fence without synthesizing another fence.
HtmlSnippet? previewSnippetForCode(String language, String code) {
  final body = code.trim();
  if (body.isEmpty) return null;
  final lang = language.trim().toLowerCase().split(RegExp(r'\s+')).first;
  final svg = _svgRoot(body);
  final svgLanguage =
      lang == 'svg' || lang == 'image/svg+xml' || lang.endsWith('.svg');
  final htmlLanguage =
      const ['html', 'htm', 'xhtml'].contains(lang) ||
      lang.endsWith('.html') ||
      lang.endsWith('.htm');
  if (svg != null &&
      (svgLanguage || lang.isEmpty || lang == 'xml' || htmlLanguage)) {
    return HtmlSnippet(
      html: _wrapSvg(svg),
      source: body,
      language: 'svg',
      kind: HtmlPreviewKind.svg,
      title: _extractTitle(svg),
    );
  }
  if (!htmlLanguage && !(lang.isEmpty && _looksLikeHtml(body))) return null;
  if (!_looksLikeHtml(body)) return null;
  return HtmlSnippet(
    html: _normalizeToDocument(body),
    source: body,
    language: 'html',
    title: _extractTitle(body),
  );
}

/// Extracts completed HTML/SVG fences, or a bare HTML/SVG document.
List<HtmlSnippet> extractHtmlSnippets(String content) {
  final text = content.trim();
  if (text.isEmpty) return const [];
  final out = <HtmlSnippet>[];
  final seen = <String>{};
  final fence = RegExp(
    r'^[ \t]{0,3}(`{3,}|~{3,})([^\n]*)\n([\s\S]*?)^[ \t]{0,3}\1[ \t]*$',
    multiLine: true,
  );
  for (final match in fence.allMatches(text.replaceAll('\r\n', '\n'))) {
    final snippet = previewSnippetForCode(match.group(2)!, match.group(3)!);
    if (snippet != null && seen.add(snippet.html)) out.add(snippet);
  }
  // Never reinterpret an unfinished code fence as a complete raw document.
  if (out.isEmpty &&
      !RegExp(r'^[ \t]{0,3}(?:`{3,}|~{3,})', multiLine: true).hasMatch(text)) {
    final lower = text.toLowerCase();
    if (lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        _svgRoot(text) != null) {
      final snippet = previewSnippetForCode('', text);
      if (snippet != null) out.add(snippet);
    }
  }
  return out;
}

bool messageHasHtmlPreview(String content) =>
    extractHtmlSnippets(content).isNotEmpty;

String? _svgRoot(String source) {
  if (!source.contains(RegExp(r'<svg(?:\s|/?>)', caseSensitive: false))) {
    return null;
  }
  try {
    final document = XmlDocument.parse(source);
    if (document.rootElement.name.qualified.toLowerCase() != 'svg') return null;
    return document.rootElement.toXmlString();
  } catch (_) {
    return null;
  }
}

bool _looksLikeHtml(String source) => RegExp(
  r'<(?:!doctype\s+html|html|head|body|div|span|p|h[1-6]|section|main|header|footer|style|script|button|nav|article|a|ul|ol|li|table|form|input|img|canvas|svg)(?:\s|/?>)',
  caseSensitive: false,
).hasMatch(source);

String _normalizeToDocument(String raw) {
  if (RegExp(r'<html(?:\s|>)|<!doctype', caseSensitive: false).hasMatch(raw)) {
    final document = html_parser.parse(raw);
    final hasViewport =
        document.head
            ?.querySelectorAll('meta')
            .any(
              (meta) => meta.attributes['name']?.toLowerCase() == 'viewport',
            ) ??
        false;
    if (hasViewport) return raw;
    document.head?.append(
      dom.Element.tag('meta')
        ..attributes['name'] = 'viewport'
        ..attributes['content'] = 'width=device-width, initial-scale=1',
    );
    return document.outerHtml;
  }
  return _document(
    raw,
    'html,body{margin:0;padding:0;font-family:system-ui,-apple-system,sans-serif;}'
    'img,video,canvas,svg{max-width:100%;height:auto;}'
    'pre{max-width:100%;overflow:auto;}',
  );
}

String _wrapSvg(String svg) => _document(
  _scalableSvg(svg),
  'html,body{margin:0;min-height:100%;font-family:system-ui,sans-serif;}'
  'body{min-height:100vh;display:grid;place-items:center;padding:16px;box-sizing:border-box;}'
  'svg{max-width:100%;height:auto;}',
);

// SVGs with only pixel dimensions otherwise crop their coordinate system when
// CSS constrains the width. Preserve a supplied viewBox and the editable source.
String _scalableSvg(String svg) {
  final root = XmlDocument.parse(svg).rootElement;
  if (root.getAttribute('viewBox') != null) return svg;
  double? pixels(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^\s*(\d+(?:\.\d+)?)\s*(?:px)?\s*$',
    ).firstMatch(value);
    final result = match == null ? null : double.tryParse(match.group(1)!);
    return result != null && result > 0 ? result : null;
  }

  final width = pixels(root.getAttribute('width'));
  final height = pixels(root.getAttribute('height'));
  if (width == null || height == null) return svg;
  root.setAttribute('viewBox', '0 0 $width $height');
  return root.toXmlString();
}

String _document(String body, String style) =>
    '''
<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>本地预览</title>
<style>$style</style>
</head><body>$body</body></html>
''';

String? _extractTitle(String source) {
  final match = RegExp(
    r'<title[^>]*>([\s\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(source);
  final title = match?.group(1)?.trim();
  if (title == null || title.isEmpty) return null;
  return title.length > 40 ? '${title.substring(0, 40)}…' : title;
}
