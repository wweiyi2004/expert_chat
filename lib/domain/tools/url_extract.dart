import 'search_provider.dart';

/// Pulls http(s) URLs out of free-form user text (max [limit]).
///
/// Skips obviously unsafe schemes/hosts via [HttpSearchProvider.isSafeHttpUrl].
List<String> extractHttpUrls(String text, {int limit = 3}) {
  if (text.trim().isEmpty || limit <= 0) return const [];
  // Match bare URLs; trim common trailing punctuation from chat.
  final re = RegExp(r'''https?://[^\s<>"'\)\]]+''', caseSensitive: false);
  final out = <String>[];
  final seen = <String>{};
  for (final m in re.allMatches(text)) {
    var raw = m.group(0) ?? '';
    raw = raw.replaceAll(RegExp(r'''[.,;:!?。，；：！？）】》」』]+$'''), '');
    if (!HttpSearchProvider.isSafeHttpUrl(raw)) continue;
    if (!seen.add(raw)) continue;
    out.add(raw);
    if (out.length >= limit) break;
  }
  return out;
}
