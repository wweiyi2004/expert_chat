import 'package:characters/characters.dart';

/// Light cleanup for user turns / model tool args before they hit a search API.
///
/// Goals: strip chat fluff, collapse whitespace, and keep the query short enough
/// that keyword engines (DDG / Bocha) still rank well. Does not call an LLM.
String normalizeSearchQuery(String raw, {int maxChars = 160}) {
  var q = raw.replaceAll('\u00a0', ' ').trim();
  if (q.isEmpty) return '';

  // Drop common chat wrappers that pollute keyword search.
  // Longer phrases first so "请问" is not partially eaten by "请".
  q = q.replaceFirst(RegExp(r'^(请问|想问一下|我想知道|告诉我|麻烦|帮我|请)[，,：:\s]*'), '');
  q = q.replaceAll(RegExp(r'[ \t\r\f]+'), ' ');
  q = q.replaceAll(RegExp(r' *\n *'), '\n');
  q = q.replaceAll(RegExp(r'\n{2,}'), '\n');
  q = q.trim();
  if (q.isEmpty) return '';

  final bounded = maxChars < 16 ? 16 : maxChars;
  if (q.characters.length <= bounded) return q;

  // Prefer cutting at a natural boundary near the limit.
  final head = q.characters.take(bounded).toString();
  final breakAt = _lastBreak(head);
  final cut = breakAt >= (bounded * 0.55).floor()
      ? head.substring(0, breakAt)
      : head;
  return cut.trimRight();
}

int _lastBreak(String s) {
  const marks = [
    ' ',
    '\n',
    '，',
    ',',
    '。',
    '.',
    '；',
    ';',
    '、',
    '？',
    '?',
    '！',
    '!',
  ];
  var best = -1;
  for (final m in marks) {
    final i = s.lastIndexOf(m);
    if (i > best) best = i;
  }
  return best;
}
