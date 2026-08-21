import 'package:characters/characters.dart';

import '../../data/models.dart';

/// One jump target in a conversation outline.
class ConversationOutlineEntry {
  const ConversationOutlineEntry({
    required this.messageId,
    required this.title,
    required this.depth,
    required this.role,
  });

  final String messageId;
  final String title;

  /// 0 = user turn, 1–6 = ATX heading level.
  final int depth;
  final MessageRole role;
}

/// Builds a table of contents from the active path: user turns plus
/// Markdown headings in assistant replies (headings inside fences skipped).
List<ConversationOutlineEntry> buildConversationOutline(
  List<ChatMessage> path,
) {
  final out = <ConversationOutlineEntry>[];
  for (final message in path) {
    if (message.role == MessageRole.user) {
      final title = _clip(_plain(_firstLine(message.content)));
      if (title.isEmpty && message.attachments.isEmpty) continue;
      out.add(
        ConversationOutlineEntry(
          messageId: message.id,
          title: title.isEmpty ? '附件' : title,
          depth: 0,
          role: MessageRole.user,
        ),
      );
      continue;
    }
    if (message.role != MessageRole.assistant) continue;
    for (final heading in _headings(message.content)) {
      final title = _clip(_plain(heading.text));
      if (title.isEmpty) continue;
      out.add(
        ConversationOutlineEntry(
          messageId: message.id,
          title: title,
          depth: heading.level,
          role: MessageRole.assistant,
        ),
      );
    }
  }
  return out;
}

({int level, String text})? _headingInLine(String line) {
  final match = RegExp(r'^(#{1,6})\s+(.+?)\s*$').firstMatch(line);
  if (match == null) return null;
  return (level: match.group(1)!.length, text: match.group(2)!);
}

Iterable<({int level, String text})> _headings(String content) sync* {
  var inFence = false;
  for (final line in content.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final heading = _headingInLine(line);
    if (heading != null) yield heading;
  }
}

String _firstLine(String content) {
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

String _plain(String raw) {
  var text = raw.trim();
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]+\)'),
    (match) => match.group(1) ?? '',
  );
  text = text.replaceAll(RegExp(r'[*_`~]+'), '');
  return text.trim();
}

String _clip(String text, {int maxChars = 28}) {
  final chars = text.characters;
  if (chars.length <= maxChars) return text;
  return '${chars.take(maxChars)}…';
}
