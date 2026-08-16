import 'dart:async';
import 'dart:math' as math;

import '../domain/memory/memory_codec.dart';
import '../domain/memory/memory_entry.dart';
import '../domain/memory/memory_safety.dart';

abstract class MemoryStore {
  Future<String?> read();
  Future<void> write(String markdown);
  Future<String> locationLabel();
}

class MemorySaveResult {
  const MemorySaveResult({required this.entry, required this.created});

  final MemoryEntry entry;
  final bool created;
}

class MemoryReplaceResult {
  const MemoryReplaceResult({
    this.entry,
    this.replacedCount = 0,
    this.created = false,
  });

  final MemoryEntry? entry;
  final int replacedCount;
  final bool created;

  bool get applied => replacedCount > 0;
}

class MemoryImportReplacement {
  const MemoryImportReplacement({
    required this.existingId,
    required this.imported,
  });

  final String existingId;
  final MemoryEntry imported;
}

class MemoryImportMergeResult {
  const MemoryImportMergeResult({
    this.added = 0,
    this.replaced = 0,
    this.skipped = 0,
  });

  final int added;
  final int replaced;
  final int skipped;
}

/// File-backed global memory repository.
///
/// Writes are serialized so rapid taps cannot race and overwrite a newer
/// revision. The Markdown file remains the source of truth; the in-memory
/// document is only a runtime cache.
class MemoryRepository {
  MemoryRepository(this._store, {this._codec = const MemoryMarkdownCodec()});

  final MemoryStore _store;
  final MemoryMarkdownCodec _codec;
  MemoryDocument? _cache;
  Future<void> _writeQueue = Future.value();

  Future<MemoryDocument> load({bool refresh = false}) async {
    if (!refresh && _cache != null) return _cache!;
    final markdown = await _store.read();
    if (markdown == null || markdown.trim().isEmpty) {
      // A read can land while a queued write has momentarily moved the main
      // file aside. Never let that empty read replace a populated cache, or
      // the next write would drop every memory. A store with no cache yet
      // still starts from an empty document.
      if (_cache != null) return _cache!;
      _cache = const MemoryDocument();
    } else {
      final decoded = _codec.decode(markdown);
      // The same swap window can also expose the previous revision (the .bak
      // or the not-yet-renamed main file). Installing it over a newer cache
      // would roll the document back, and the next queued write would then
      // persist that older entry set — silently dropping memories. Only
      // versions at least as new as the cache may replace it; an equal
      // revision is still accepted so externally hand-edited files reload.
      if (_cache == null || decoded.revision >= _cache!.revision) {
        _cache = decoded;
      }
    }
    return _cache!;
  }

  Future<String> locationLabel() => _store.locationLabel();

  Future<MemorySaveResult> add({
    required String content,
    String? sourceConversationId,
    String? sourceMessageId,
    String? sourceRole,
    bool pinned = true,
  }) {
    final completer = Completer<MemorySaveResult>();
    _enqueue(() async {
      try {
        final normalized = MemorySafety.normalize(content);
        final current = await load();
        final duplicate = current.entries.cast<MemoryEntry?>().firstWhere(
          (entry) => _dedupeKey(entry!.content) == _dedupeKey(normalized),
          orElse: () => null,
        );
        if (duplicate != null) {
          completer.complete(
            MemorySaveResult(entry: duplicate, created: false),
          );
          return;
        }
        final entry = MemoryEntry(
          content: normalized,
          sourceConversationId: sourceConversationId,
          sourceMessageId: sourceMessageId,
          sourceRole: sourceRole,
          pinned: pinned,
        );
        await _save([...current.entries, entry]);
        completer.complete(MemorySaveResult(entry: entry, created: true));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  /// Atomically removes the confirmed related entries and writes their
  /// replacement in one document revision. The model can name at most a small
  /// bounded set of ids, and the user sees every target before this is called.
  Future<MemoryReplaceResult> replace({
    required Iterable<String> replacedIds,
    required String content,
    String? sourceConversationId,
    String? sourceMessageId,
    String? sourceRole,
  }) {
    final completer = Completer<MemoryReplaceResult>();
    _enqueue(() async {
      try {
        final normalized = MemorySafety.normalize(content);
        final ids = replacedIds.toSet();
        final current = await load();
        final targets = current.entries
            .where((entry) => ids.contains(entry.id))
            .toList(growable: false);
        if (targets.isEmpty) {
          completer.complete(const MemoryReplaceResult());
          return;
        }

        final remaining = current.entries
            .where((entry) => !ids.contains(entry.id))
            .toList();
        final duplicate = remaining.cast<MemoryEntry?>().firstWhere(
          (entry) => _dedupeKey(entry!.content) == _dedupeKey(normalized),
          orElse: () => null,
        );
        if (duplicate != null) {
          await _save(remaining);
          completer.complete(
            MemoryReplaceResult(
              entry: duplicate,
              replacedCount: targets.length,
            ),
          );
          return;
        }

        final replacement = MemoryEntry(
          content: normalized,
          sourceConversationId: sourceConversationId,
          sourceMessageId: sourceMessageId,
          sourceRole: sourceRole,
          pinned: targets.any((entry) => entry.pinned),
        );
        await _save([...remaining, replacement]);
        completer.complete(
          MemoryReplaceResult(
            entry: replacement,
            replacedCount: targets.length,
            created: true,
          ),
        );
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  /// Applies a reviewed backup merge in one Markdown revision. Every entry is
  /// revalidated here so a stale or forged preview cannot bypass file safety.
  Future<MemoryImportMergeResult> mergeImport({
    required Iterable<MemoryEntry> additions,
    required Iterable<MemoryImportReplacement> replacements,
  }) {
    final completer = Completer<MemoryImportMergeResult>();
    _enqueue(() async {
      try {
        final current = await load();
        final entries = [...current.entries];
        var added = 0;
        var replaced = 0;
        var skipped = 0;

        for (final mutation in replacements) {
          final index = entries.indexWhere(
            (entry) => entry.id == mutation.existingId,
          );
          if (index < 0) {
            skipped++;
            continue;
          }
          final imported = _validatedImported(
            mutation.imported,
            id: entries[index].id,
          );
          final duplicateIndex = entries.indexWhere(
            (entry) =>
                entry.id != mutation.existingId &&
                _dedupeKey(entry.content) == _dedupeKey(imported.content),
          );
          if (duplicateIndex >= 0) {
            entries.removeAt(index);
          } else {
            entries[index] = imported;
          }
          replaced++;
        }

        for (final raw in additions) {
          final imported = _validatedImported(raw);
          final duplicate = entries.any(
            (entry) =>
                entry.id == imported.id ||
                _dedupeKey(entry.content) == _dedupeKey(imported.content),
          );
          if (duplicate) {
            skipped++;
            continue;
          }
          entries.add(imported);
          added++;
        }

        if (added > 0 || replaced > 0) await _save(entries);
        completer.complete(
          MemoryImportMergeResult(
            added: added,
            replaced: replaced,
            skipped: skipped,
          ),
        );
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> update(
    String id, {
    required String content,
    required bool pinned,
  }) {
    final completer = Completer<void>();
    _enqueue(() async {
      try {
        final normalized = MemorySafety.normalize(content);
        final current = await load();
        final index = current.entries.indexWhere((entry) => entry.id == id);
        if (index < 0) throw StateError('要更新的记忆不存在。');
        final entries = [...current.entries];
        entries[index] = entries[index].copyWith(
          content: normalized,
          pinned: pinned,
          updatedAt: DateTime.now(),
        );
        await _save(entries);
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> delete(String id) {
    final completer = Completer<void>();
    _enqueue(() async {
      try {
        final current = await load();
        final entries = current.entries
            .where((entry) => entry.id != id)
            .toList();
        if (entries.length != current.entries.length) {
          await _save(entries);
        }
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<MemoryRecall> recall(
    String query, {
    int maxItems = 8,
    int maxChars = 4000,
  }) async {
    final current = await load();
    if (current.entries.isEmpty || maxItems <= 0 || maxChars <= 0) {
      return const MemoryRecall([]);
    }
    final queryTerms = _terms(query);
    final scored = <({MemoryEntry entry, int score})>[];
    for (final entry in current.entries) {
      // Desktop users may edit the Markdown file outside the app. Re-check at
      // recall time so manually pasted credentials are never sent upstream.
      if (MemorySafety.sensitiveReason(entry.content) != null ||
          entry.content.length > MemorySafety.maxContentChars) {
        continue;
      }
      final entryTerms = _terms(entry.content);
      var score = entry.pinned ? 10000 : 0;
      for (final term in queryTerms) {
        if (entryTerms.contains(term)) score += math.max(2, term.length);
      }
      if (score > 0) scored.add((entry: entry, score: score));
    }
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byUpdatedAt = b.entry.updatedAt.compareTo(a.entry.updatedAt);
      if (byUpdatedAt != 0) return byUpdatedAt;
      // Dart List.sort 不稳定,用 id 兜底保证同分条目顺序确定。
      return a.entry.id.compareTo(b.entry.id);
    });

    // 常驻记忆最多占用 60% 的条数配额,避免常驻较多时按需匹配永远进不了召回。
    final maxPinnedItems = math.max(1, (maxItems * 0.6).floor());
    var pinnedCount = 0;
    var usedChars = 0;
    final selected = <MemoryEntry>[];
    for (final item in scored) {
      if (selected.length >= maxItems) break;
      final cost = item.entry.content.length + 3;
      if (usedChars + cost > maxChars) break; // 预算耗尽即停止,不再寻找更小的条目。
      if (item.entry.pinned) {
        if (pinnedCount >= maxPinnedItems) continue; // 常驻配额已满,让位给按需匹配。
        pinnedCount++;
      }
      selected.add(item.entry);
      usedChars += cost;
    }
    return MemoryRecall(List.unmodifiable(selected));
  }

  void _enqueue(Future<void> Function() operation) {
    _writeQueue = _writeQueue
        .catchError((Object _) {})
        .then((_) => operation());
  }

  Future<void> _save(List<MemoryEntry> entries) async {
    final current = _cache ?? const MemoryDocument();
    final next = MemoryDocument(
      entries: List.unmodifiable(entries),
      revision: current.revision + 1,
      updatedAt: DateTime.now(),
    );
    await _store.write(_codec.encode(next));
    _cache = next;
  }

  static String _dedupeKey(String value) {
    // 连续空白压成一个空格而非删除,避免 "api key" 与 "apikey" 被误判为重复;
    // 中文不使用空格分词,与汉字相邻的空格视为排版差异,一并去掉。
    final collapsed = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final cjk = RegExp(r'[㐀-鿿]');
    final result = StringBuffer();
    for (var i = 0; i < collapsed.length; i++) {
      final char = collapsed[i];
      final spaceTouchesCjk =
          char == ' ' &&
          ((i > 0 && cjk.hasMatch(collapsed[i - 1])) ||
              (i + 1 < collapsed.length && cjk.hasMatch(collapsed[i + 1])));
      if (!spaceTouchesCjk) result.write(char);
    }
    return result.toString();
  }

  static MemoryEntry _validatedImported(MemoryEntry entry, {String? id}) {
    final safeId = id ?? entry.id;
    if (!RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(safeId)) {
      throw const MemoryValidationException('导入记忆的 ID 格式不正确。');
    }
    return MemoryEntry(
      id: safeId,
      content: MemorySafety.normalize(entry.content),
      pinned: entry.pinned,
      sourceConversationId: entry.sourceConversationId,
      sourceMessageId: entry.sourceMessageId,
      sourceRole: entry.sourceRole,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
    );
  }

  static Set<String> _terms(String value) {
    final lower = value.toLowerCase();
    final terms = <String>{
      ...RegExp(
        r'[a-z0-9_+#.-]{2,}',
      ).allMatches(lower).map((match) => match.group(0)!),
    };
    final cjk = RegExp(
      r'[\u3400-\u9fff]',
    ).allMatches(lower).map((match) => match.group(0)!);
    final chars = cjk.toList();
    terms.addAll(chars);
    for (var i = 0; i + 1 < chars.length; i++) {
      terms.add('${chars[i]}${chars[i + 1]}');
    }
    return terms;
  }
}
