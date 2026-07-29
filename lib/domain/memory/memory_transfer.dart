import 'memory_codec.dart';
import 'memory_entry.dart';
import 'memory_safety.dart';

enum MemoryImportStatus { newEntry, duplicate, conflict }

class MemoryImportItem {
  const MemoryImportItem({
    required this.imported,
    required this.status,
    this.existing,
  });

  final MemoryEntry imported;
  final MemoryImportStatus status;
  final MemoryEntry? existing;
}

enum MemoryImportAction { add, useImported, keepBoth }

class MemoryImportSelection {
  const MemoryImportSelection({required this.item, required this.action});

  final MemoryImportItem item;
  final MemoryImportAction action;
}

class MemoryImportPlan {
  const MemoryImportPlan({
    required this.items,
    required this.sourceEntryCount,
    this.blockedCount = 0,
  });

  final List<MemoryImportItem> items;
  final int sourceEntryCount;
  final int blockedCount;

  int count(MemoryImportStatus status) =>
      items.where((item) => item.status == status).length;

  int get newCount => count(MemoryImportStatus.newEntry);
  int get duplicateCount => count(MemoryImportStatus.duplicate);
  int get conflictCount => count(MemoryImportStatus.conflict);

  List<MemoryImportItem> get actionableItems => [
    for (final item in items)
      if (item.status != MemoryImportStatus.duplicate) item,
  ];
}

class MemoryImportFormatException implements Exception {
  const MemoryImportFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Pure, offline validation and merge planning for Markdown memory backups.
class MemoryTransferService {
  const MemoryTransferService({this.codec = const MemoryMarkdownCodec()});

  final MemoryMarkdownCodec codec;

  static const int maxBackupBytes = 2 * 1024 * 1024;
  static const int maxImportEntries = 1000;

  String exportDocument(MemoryDocument document) => codec.encode(document);

  MemoryImportPlan previewImport(
    String markdown, {
    required MemoryDocument current,
  }) {
    if (!markdown.contains('# Expert Chat 长期记忆') ||
        !RegExp(r'^schema:\s*1\s*$', multiLine: true).hasMatch(markdown)) {
      throw const MemoryImportFormatException('所选文件不是 Expert Chat 记忆备份。');
    }

    final importedDocument = codec.decode(markdown);
    if (importedDocument.entries.isEmpty) {
      throw const MemoryImportFormatException('备份中没有可导入的记忆。');
    }
    if (importedDocument.entries.length > maxImportEntries) {
      throw const MemoryImportFormatException('备份中的记忆超过 1000 条，已拒绝导入。');
    }

    final currentById = {for (final entry in current.entries) entry.id: entry};
    final currentByContent = <String, MemoryEntry>{
      for (final entry in current.entries) _contentKey(entry.content): entry,
    };
    final currentBySource = <String, MemoryEntry>{};
    for (final entry in current.entries) {
      final key = _sourceKey(entry);
      if (key != null) currentBySource[key] = entry;
    }
    final seenIds = <String>{};
    final seenContents = <String>{};
    final items = <MemoryImportItem>[];
    var blocked = 0;

    for (final raw in importedDocument.entries) {
      if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(raw.id)) {
        blocked++;
        continue;
      }
      String content;
      try {
        content = MemorySafety.normalize(raw.content);
      } on MemoryValidationException {
        blocked++;
        continue;
      }

      final imported = MemoryEntry(
        id: raw.id,
        content: content,
        pinned: raw.pinned,
        sourceConversationId: raw.sourceConversationId,
        sourceMessageId: raw.sourceMessageId,
        sourceRole: raw.sourceRole,
        createdAt: raw.createdAt,
        updatedAt: raw.updatedAt,
      );
      final contentKey = _contentKey(content);
      if (!seenIds.add(imported.id) || !seenContents.add(contentKey)) {
        items.add(
          MemoryImportItem(
            imported: imported,
            status: MemoryImportStatus.duplicate,
          ),
        );
        continue;
      }

      final sameId = currentById[imported.id];
      if (sameId != null) {
        items.add(
          MemoryImportItem(
            imported: imported,
            existing: sameId,
            status: _sameUserValue(sameId, imported)
                ? MemoryImportStatus.duplicate
                : MemoryImportStatus.conflict,
          ),
        );
        continue;
      }

      final sameContent = currentByContent[contentKey];
      if (sameContent != null) {
        items.add(
          MemoryImportItem(
            imported: imported,
            existing: sameContent,
            status: MemoryImportStatus.duplicate,
          ),
        );
        continue;
      }

      final sourceKey = _sourceKey(imported);
      final sameSource = sourceKey == null ? null : currentBySource[sourceKey];
      if (sameSource != null) {
        items.add(
          MemoryImportItem(
            imported: imported,
            existing: sameSource,
            status: MemoryImportStatus.conflict,
          ),
        );
        continue;
      }

      items.add(
        MemoryImportItem(
          imported: imported,
          status: MemoryImportStatus.newEntry,
        ),
      );
    }

    return MemoryImportPlan(
      items: List.unmodifiable(items),
      sourceEntryCount: importedDocument.entries.length,
      blockedCount: blocked,
    );
  }

  static bool _sameUserValue(MemoryEntry a, MemoryEntry b) =>
      _contentKey(a.content) == _contentKey(b.content) && a.pinned == b.pinned;

  static String _contentKey(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static String? _sourceKey(MemoryEntry entry) {
    final conversationId = entry.sourceConversationId?.trim() ?? '';
    final messageId = entry.sourceMessageId?.trim() ?? '';
    if (conversationId.isEmpty || messageId.isEmpty) return null;
    return '$conversationId::$messageId';
  }
}
