import '../domain/workbench/changes/review_path_identity.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/workbench/changes/work_change_store.dart';
import '../domain/workbench/changes/work_file_change.dart';

export '../domain/workbench/changes/work_file_change.dart';

(String, String) _physicalReviewLocation(
  String target,
  String scope,
  String path,
) {
  final location = reviewPhysicalPath(target, scope, path);
  if (location != null) {
    return (location.authority, location.physical);
  }
  return ('$target:$scope', p.posix.normalize(path.replaceAll(r'\', '/')));
}

bool _affectedPublishedArtifact(WorkFileChange entry, WorkFileChange changed) {
  if (!entry.isDelivery || entry.conversationId != changed.conversationId) {
    return false;
  }
  final a = _physicalReviewLocation(entry.target, entry.scope, entry.path),
      b = _physicalReviewLocation(changed.target, changed.scope, changed.path);
  if (a.$1 != b.$1) return false;
  if (a.$2 == b.$2) return entry.afterHash != changed.afterHash;
  return entry.artifactManifest?['kind'] == 'directory' &&
      (a.$2 == '.' || b.$2.startsWith('${a.$2}/'));
}

final workChangesProvider = NotifierProvider<WorkChanges, List<WorkFileChange>>(
  WorkChanges.new,
);

/// Device-local review history. Recording occurs after a successful file tool
/// write; raw terminal commands are outside this snapshot mechanism.
class WorkChanges extends Notifier<List<WorkFileChange>> {
  Future<void> flush() => _pending;
  Future<void> _pending = Future.value();
  late Future<void> ready;
  final _readSnapshots = <(String, String, String, String, String), String>{};
  final _directories =
      <(String, String, String, String, String), Set<String>>{};
  final _commandStarted = <(String, String, String)>{};
  Future<void> commandStarted(
    String conversation,
    String assistant,
    String target,
  ) {
    _commandStarted.add((conversation, assistant, target));
    // Shell commands may change any file, including previously published ones.
    return _update((entries) {
      bool matches(WorkFileChange entry) =>
          entry.conversationId == conversation &&
          entry.assistantId == assistant &&
          entry.deliveryHash != null;
      if (!entries.any(matches)) return entries;
      return [
        for (final entry in entries)
          if (matches(entry)) entry.withDelivery(false) else entry,
      ];
    });
  }

  String _relative(String path) => path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'^\./'), '')
      .replaceFirst(RegExp(r'/$'), '');
  void rememberDirectory(
    String conversation,
    String assistant,
    String target,
    String scope,
    String path,
    Iterable<String> names,
  ) {
    if (_commandStarted.contains((conversation, assistant, target))) return;
    final directory = _relative(path);
    _directories.putIfAbsent((
      conversation,
      assistant,
      target,
      scope,
      directory.isEmpty ? '.' : directory,
    ), () => names.toSet());
  }

  bool wasAbsent(
    String conversation,
    String assistant,
    String target,
    String scope,
    String path,
  ) {
    final parts = _relative(path).split('/');
    if (parts.contains('..')) return false;
    for (var i = 0; i < parts.length; i++) {
      final parent = i == 0 ? '.' : parts.take(i).join('/');
      final entries =
          _directories[(conversation, assistant, target, scope, parent)];
      if (entries != null && !entries.contains(parts[i])) return true;
    }
    return false;
  }

  void rememberRead(
    String conversation,
    String assistant,
    String target,
    String scope,
    String path,
    String content,
  ) {
    if (_commandStarted.contains((conversation, assistant, target))) return;
    _readSnapshots.putIfAbsent((
      conversation,
      assistant,
      target,
      scope,
      path,
    ), () => content);
  }

  String? readSnapshot(
    String conversation,
    String assistant,
    String target,
    String scope,
    String path,
  ) => _readSnapshots[(conversation, assistant, target, scope, path)];

  void forgetReads(String conversation, String assistant) {
    _directories.removeWhere(
      (key, _) => key.$1 == conversation && key.$2 == assistant,
    );
    _commandStarted.removeWhere(
      (key) => key.$1 == conversation && key.$2 == assistant,
    );
    _readSnapshots.removeWhere(
      (key, _) => key.$1 == conversation && key.$2 == assistant,
    );
  }

  @override
  List<WorkFileChange> build() {
    ready = Future<void>.microtask(() async {
      final entries = await loadWorkChanges();
      if (ref.mounted) state = List.unmodifiable(entries);
    });
    _pending = ready.catchError((Object _) {});
    return const [];
  }

  Future<void> _update(
    List<WorkFileChange> Function(List<WorkFileChange>) update,
  ) {
    final operation = _pending.then((_) async {
      await ready;
      if (!ref.mounted) return;
      final next = update(state);
      if (identical(next, state)) return;
      await saveWorkChanges(next);
      if (ref.mounted) state = List.unmodifiable(next);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> record({
    required String conversationId,
    String assistantId = '',
    String roundId = '',
    Map<String, dynamic>? artifactManifest,
    bool beforeKnown = true,
    bool textSnapshot = true,
    required String target,
    String scope = 'root',
    required String path,
    String? before,
    required String? after,
    bool deleted = false,
    String? beforeHash,
    required String afterHash,
  }) => _update((entries) {
    // Keep the earliest snapshot only while successive writes form a continuous
    // chain. A human/external edit starts a separate review entry.
    final previous = entries
        .where(
          (entry) =>
              entry.conversationId == conversationId &&
              entry.assistantId == assistantId &&
              entry.roundId == roundId &&
              entry.target == target &&
              entry.scope == scope &&
              entry.path == path &&
              !entry.reverted,
        )
        .lastOrNull;
    final continuous =
        textSnapshot && previous != null && previous.afterHash == beforeHash;
    final change = WorkFileChange(
      id: continuous ? previous.id : const Uuid().v4(),
      conversationId: conversationId,
      assistantId: assistantId,
      roundId: roundId,
      artifactManifest: artifactManifest,
      textSnapshot: textSnapshot,
      deleted: deleted,
      beforeKnown:
          textSnapshot && (continuous ? previous.beforeKnown : beforeKnown),
      target: target,
      scope: scope,
      path: path,
      before: continuous ? previous.before : before,
      after: after,
      beforeHash: continuous ? previous.beforeHash : beforeHash,
      afterHash: afterHash,
      updatedAt: DateTime.now(),
    );
    return [
      for (final entry in entries)
        if (entry.id != change.id)
          _affectedPublishedArtifact(entry, change)
              ? entry.withDelivery(false)
              : entry,
      change,
    ];
  });

  Future<void> markReverted(WorkFileChange restored) => _update(
    (entries) => [
      for (final entry in entries)
        if (entry.id == restored.id && entry.afterHash == restored.afterHash)
          entry.withReverted()
        else
          entry,
    ],
  );

  /// Replace the final-artifact manifest for this message/target/scope. Version
  /// hashes come from successful reads, not model-provided assertions.
  Future<void> registerDeliveries({
    required String conversationId,
    required String assistantId,
    required String target,
    required String scope,
    required Map<String, String> verifiedFiles,
  }) => _update((entries) {
    final matching = entries
        .where(
          (entry) =>
              entry.conversationId == conversationId &&
              entry.assistantId == assistantId &&
              entry.target == target &&
              entry.scope == scope,
        )
        .toList();
    final latest = <String, WorkFileChange>{
      for (final entry in matching) entry.path: entry,
    };
    for (final file in verifiedFiles.entries) {
      final entry = latest[file.key];
      if (entry == null || entry.reverted || entry.afterHash != file.value) {
        throw StateError('交付文件版本已变化，请重新登记：${file.key}');
      }
    }
    return [
      for (final entry in entries)
        if (matching.contains(entry))
          entry.withDelivery(
            latest[entry.path]?.id == entry.id &&
                verifiedFiles[entry.path] == entry.afterHash,
          )
        else
          entry,
    ];
  });

  Future<void> removeConversation(String conversationId) => _update(
    (entries) =>
        entries.where((e) => e.conversationId != conversationId).toList(),
  );
}
