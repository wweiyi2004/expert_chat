import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/memory_repository.dart';
import '../domain/memory/memory_candidate_service.dart';
import '../domain/memory/memory_entry.dart';
import '../domain/memory/memory_transfer.dart';

class MemoryState {
  const MemoryState({this.entries = const [], this.locationLabel = ''});

  final List<MemoryEntry> entries;
  final String locationLabel;
}

class MemoryCandidateApplyResult {
  const MemoryCandidateApplyResult({
    this.added = 0,
    this.replaced = 0,
    this.skipped = 0,
  });

  final int added;
  final int replaced;
  final int skipped;

  int get saved => added + replaced;
}

class MemoryController extends AsyncNotifier<MemoryState> {
  @override
  Future<MemoryState> build() async {
    final repository = ref.read(memoryRepositoryProvider);
    final results = await Future.wait([
      repository.load(),
      repository.locationLabel(),
    ]);
    final document = results[0] as MemoryDocument;
    return MemoryState(
      entries: document.entries.reversed.toList(growable: false),
      locationLabel: results[1] as String,
    );
  }

  Future<MemorySaveResult> add({
    required String content,
    String? sourceConversationId,
    String? sourceMessageId,
    String? sourceRole,
  }) async {
    final result = await ref
        .read(memoryRepositoryProvider)
        .add(
          content: content,
          sourceConversationId: sourceConversationId,
          sourceMessageId: sourceMessageId,
          sourceRole: sourceRole,
        );
    await reload();
    return result;
  }

  /// Writes an explicitly confirmed candidate batch, then refreshes the UI
  /// once. The repository still serializes each file mutation and deduplicates
  /// against memories that may have been added in the meantime.
  Future<MemoryCandidateApplyResult> applyConfirmedCandidates(
    Iterable<MemoryCandidateSelection> selections, {
    required String sourceConversationId,
  }) async {
    var added = 0;
    var replaced = 0;
    var skipped = 0;
    final repository = ref.read(memoryRepositoryProvider);
    for (final selection in selections) {
      final candidate = selection.candidate;
      final sourceMessageId = candidate.sourceMessageIds.isEmpty
          ? null
          : candidate.sourceMessageIds.first;
      if (selection.mode == MemoryCandidateWriteMode.replace) {
        final result = await repository.replace(
          replacedIds: candidate.relatedMemories.map((entry) => entry.id),
          content: candidate.content,
          sourceConversationId: sourceConversationId,
          sourceMessageId: sourceMessageId,
          sourceRole: 'user_candidate_replacement',
        );
        if (result.applied) {
          replaced++;
        } else {
          skipped++;
        }
      } else {
        final result = await repository.add(
          content: candidate.content,
          sourceConversationId: sourceConversationId,
          sourceMessageId: sourceMessageId,
          sourceRole: candidate.hasExistingRelation
              ? 'user_candidate_kept_both'
              : 'user_candidate_confirmed',
        );
        if (result.created) {
          added++;
        } else {
          skipped++;
        }
      }
    }
    await reload();
    return MemoryCandidateApplyResult(
      added: added,
      replaced: replaced,
      skipped: skipped,
    );
  }

  Future<String> exportMarkdown() async {
    final document = await ref
        .read(memoryRepositoryProvider)
        .load(refresh: true);
    return ref.read(memoryTransferServiceProvider).exportDocument(document);
  }

  Future<MemoryImportPlan> previewImport(String markdown) async {
    final current = await ref
        .read(memoryRepositoryProvider)
        .load(refresh: true);
    return ref
        .read(memoryTransferServiceProvider)
        .previewImport(markdown, current: current);
  }

  Future<MemoryImportMergeResult> applyImport(
    Iterable<MemoryImportSelection> selections,
  ) async {
    final additions = <MemoryEntry>[];
    final replacements = <MemoryImportReplacement>[];
    for (final selection in selections) {
      final item = selection.item;
      switch (selection.action) {
        case MemoryImportAction.add:
          additions.add(item.imported);
        case MemoryImportAction.useImported:
          final existing = item.existing;
          if (existing != null) {
            replacements.add(
              MemoryImportReplacement(
                existingId: existing.id,
                imported: item.imported,
              ),
            );
          }
        case MemoryImportAction.keepBoth:
          additions.add(
            MemoryEntry(
              content: item.imported.content,
              pinned: item.imported.pinned,
              sourceConversationId: item.imported.sourceConversationId,
              sourceMessageId: item.imported.sourceMessageId,
              sourceRole: item.imported.sourceRole,
              createdAt: item.imported.createdAt,
              updatedAt: item.imported.updatedAt,
            ),
          );
      }
    }
    final result = await ref
        .read(memoryRepositoryProvider)
        .mergeImport(additions: additions, replacements: replacements);
    await reload();
    return result;
  }

  Future<void> updateEntry(
    String id, {
    required String content,
    required bool pinned,
  }) async {
    await ref
        .read(memoryRepositoryProvider)
        .update(id, content: content, pinned: pinned);
    await reload();
  }

  Future<void> togglePinned(MemoryEntry entry) =>
      updateEntry(entry.id, content: entry.content, pinned: !entry.pinned);

  Future<void> delete(String id) async {
    await ref.read(memoryRepositoryProvider).delete(id);
    await reload();
  }

  Future<void> reload({bool refresh = false}) async {
    final repository = ref.read(memoryRepositoryProvider);
    final document = await repository.load(refresh: refresh);
    final location = state.value?.locationLabel.isNotEmpty == true
        ? state.value!.locationLabel
        : await repository.locationLabel();
    state = AsyncData(
      MemoryState(
        entries: document.entries.reversed.toList(growable: false),
        locationLabel: location,
      ),
    );
  }
}

final memoryControllerProvider =
    AsyncNotifierProvider<MemoryController, MemoryState>(MemoryController.new);
