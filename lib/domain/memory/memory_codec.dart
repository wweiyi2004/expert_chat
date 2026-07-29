import 'memory_entry.dart';

/// Human-readable Markdown codec for the managed global memory file.
///
/// Each memory is a one-line bullet so users can inspect or edit the file.
/// Indented metadata remains readable while giving the app stable ids and
/// provenance. Decoding is intentionally lenient: malformed manual lines are
/// skipped instead of making the whole memory vault unavailable.
class MemoryMarkdownCodec {
  const MemoryMarkdownCodec();

  static final _entryPattern = RegExp(r'^- \[id:([^\]]+)\] (.*)$');
  static final _metaPattern = RegExp(r'^  - ([a-z_]+):\s?(.*)$');

  String encode(MemoryDocument document) {
    final updated = document.updatedAt ?? DateTime.now();
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('schema: 1')
      ..writeln('scope: global')
      ..writeln('revision: ${document.revision}')
      ..writeln('updated_at: ${updated.toIso8601String()}')
      ..writeln('---')
      ..writeln()
      ..writeln('# Expert Chat 长期记忆')
      ..writeln()
      ..writeln('> 由 Expert Chat 管理。每条内容均由用户手动保存或确认。')
      ..writeln();
    for (final entry in document.entries) {
      buffer
        ..writeln('- [id:${entry.id}] ${_singleLine(entry.content)}')
        ..writeln('  - pinned: ${entry.pinned}')
        ..writeln('  - created_at: ${entry.createdAt.toIso8601String()}')
        ..writeln('  - updated_at: ${entry.updatedAt.toIso8601String()}');
      if (entry.sourceConversationId != null) {
        buffer.writeln(
          '  - source_conversation_id: ${entry.sourceConversationId}',
        );
      }
      if (entry.sourceMessageId != null) {
        buffer.writeln('  - source_message_id: ${entry.sourceMessageId}');
      }
      if (entry.sourceRole != null) {
        buffer.writeln('  - source_role: ${entry.sourceRole}');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  MemoryDocument decode(String markdown) {
    final lines = markdown.split(RegExp(r'\r?\n'));
    var revision = 0;
    DateTime? documentUpdatedAt;
    for (final line in lines.take(12)) {
      if (line.startsWith('revision:')) {
        revision = int.tryParse(line.substring('revision:'.length).trim()) ?? 0;
      } else if (line.startsWith('updated_at:')) {
        documentUpdatedAt = DateTime.tryParse(
          line.substring('updated_at:'.length).trim(),
        );
      }
    }

    final entries = <MemoryEntry>[];
    var index = 0;
    while (index < lines.length) {
      final match = _entryPattern.firstMatch(lines[index]);
      if (match == null) {
        index++;
        continue;
      }
      final id = match.group(1)?.trim() ?? '';
      final content = match.group(2)?.trim() ?? '';
      final metadata = <String, String>{};
      index++;
      while (index < lines.length) {
        final meta = _metaPattern.firstMatch(lines[index]);
        if (meta == null) break;
        metadata[meta.group(1)!] = meta.group(2)?.trim() ?? '';
        index++;
      }
      if (id.isEmpty || content.isEmpty) continue;
      entries.add(
        MemoryEntry(
          id: id,
          content: content,
          pinned: metadata['pinned'] != 'false',
          sourceConversationId: _nullable(metadata['source_conversation_id']),
          sourceMessageId: _nullable(metadata['source_message_id']),
          sourceRole: _nullable(metadata['source_role']),
          createdAt: _time(metadata['created_at']),
          updatedAt: _time(metadata['updated_at']),
        ),
      );
    }

    return MemoryDocument(
      entries: List.unmodifiable(entries),
      revision: revision,
      updatedAt: documentUpdatedAt,
    );
  }

  static String _singleLine(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String? _nullable(String? value) =>
      value == null || value.isEmpty ? null : value;

  static DateTime _time(String? value) =>
      DateTime.tryParse(value ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
}
