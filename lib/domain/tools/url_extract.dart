import 'search_provider.dart';

/// Pulls http(s) URLs out of free-form user text (max [limit]).
///
/// Skips obviously unsafe schemes/hosts via [HttpSearchProvider.isSafeHttpUrl].
List<String> extractHttpUrls(String text, {int limit = 3}) {
  if (text.trim().isEmpty || limit <= 0) return const [];
  // Match bare URLs; parentheses are allowed so Wikipedia-style
  // "Foo_(bar)" titles survive — unbalanced brackets are dropped afterwards
  // and common trailing chat punctuation is trimmed below.
  final re = RegExp(r'''https?://[^\s<>"'\]]+''', caseSensitive: false);
  final out = <String>[];
  final seen = <String>{};
  for (final m in re.allMatches(text)) {
    var raw = m.group(0) ?? '';
    raw = raw.replaceAll(RegExp(r'''[.,;:!?。，；：！？）】》」』]+$'''), '');
    raw = _balanceParens(raw);
    if (!HttpSearchProvider.isSafeHttpUrl(raw)) continue;
    if (!seen.add(raw)) continue;
    out.add(raw);
    if (out.length >= limit) break;
  }
  return out;
}

/// Keeps balanced parentheses inside a URL (Wikipedia-style titles) while
/// dropping an unmatched trailing `)` (chat punctuation) and cutting an
/// unclosed `(` (a truncated link).
String _balanceParens(String url) {
  var result = url;
  while (result.endsWith(')') && _parenDepth(result) < 0) {
    result = result.substring(0, result.length - 1);
  }
  while (_parenDepth(result) > 0) {
    final idx = result.lastIndexOf('(');
    if (idx < 0) break;
    result = result.substring(0, idx);
  }
  return result;
}

int _parenDepth(String value) {
  var depth = 0;
  for (final code in value.codeUnits) {
    if (code == 0x28) depth++; // (
    if (code == 0x29) depth--; // )
  }
  return depth;
}
