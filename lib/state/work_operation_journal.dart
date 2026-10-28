import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';

final workOperationJournalProvider = Provider<WorkOperationJournal>(
  (ref) => WorkOperationJournal(
    read: () => ref.read(sharedPrefsProvider).getString('workOperations.v1'),
    write: (value) =>
        ref.read(sharedPrefsProvider).setString('workOperations.v1', value),
  ),
);

enum WorkOperationOutcome { completed, failed, unknown }

class WorkOperationJournal {
  WorkOperationJournal({
    required String? Function() read,
    required this.write,
  }) {
    final raw = read();
    try {
      final decoded = jsonDecode(raw ?? '[]');
      final list = decoded is Map
          ? decoded['entries'] as List
          : decoded as List;
      entries.addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
      if (decoded is Map) corruptBackup = decoded['corrupt_backup'] as String?;
      for (final e in entries) {
        if (e['status'] == 'started') e['status'] = 'unknown';
      }
    } catch (_) {
      corrupt = true;
      corruptBackup = raw;
    }
  }
  bool corrupt = false;
  String? corruptBackup;
  final entries = <Map<String, dynamic>>[];
  final Future<bool> Function(String) write;
  Future<void> _pending = Future.value();
  Future<T> _transaction<T>(Future<T> Function() action) {
    final result = _pending.catchError((Object _) {}).then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _persist(List<Map<String, dynamic>> candidate) async {
    // Keep every unresolved/active record. Terminal records are bounded audit
    // tails; original conversation/tool records remain the source of history.
    final counts = <String, int>{};
    var terminalCount = 0;
    final retained = <Map<String, dynamic>>[];
    for (final entry in candidate.reversed) {
      final terminal = !{'started', 'unknown'}.contains(entry['status']);
      final conversation = entry['conversation'] as String? ?? '';
      if (terminal) {
        if (terminalCount >= 2048 || (counts[conversation] ?? 0) >= 256) {
          continue;
        }
        terminalCount++;
        counts[conversation] = (counts[conversation] ?? 0) + 1;
      }
      retained.add(entry);
    }
    final ordered = retained.reversed.toList();
    final data = jsonEncode({
      'entries': ordered,
      if (corruptBackup != null) 'corrupt_backup': corruptBackup,
    });
    if (!await write(data)) throw StateError('执行日志保存失败，工具未获准继续');
    entries
      ..clear()
      ..addAll(ordered);
  }

  String _reviewIdentity(Map<String, dynamic> entry) =>
      entry['identity'] as String? ??
      'legacy:${sha256.convert(utf8.encode(jsonEncode({
        for (final key in ['conversation', 'task', 'call_id', 'tool', 'fingerprint', 'started_at']) key: entry[key],
      })))}';
  String? get corruptionDigest => corrupt
      ? sha256.convert(utf8.encode(corruptBackup ?? '')).toString()
      : null;
  List<Map<String, dynamic>> unresolved(String conversation) => entries
      .where(
        (e) => e['conversation'] == conversation && e['status'] == 'unknown',
      )
      .map((e) => {...e, 'review_identity': _reviewIdentity(e)})
      .toList();
  Future<String> run({
    required String conversation,
    required String task,
    required String callId,
    required String tool,
    required String arguments,
    String agent = 'root',
    String request = 'default',
    WorkOperationOutcome Function(String)? classify,
    required Future<String> Function() operation,
  }) async {
    final fingerprint = sha256
        .convert(utf8.encode('$tool\n$arguments'))
        .toString();
    final identity =
        '$conversation\u0000$task\u0000$agent\u0000$request\u0000$callId';
    final blocked = await _transaction<String?>(() async {
      // Unknown outcomes stay listed for review but never gate new calls; only
      // a corrupt journal blocks, because replay can no longer be ruled out.
      if (corrupt) {
        return jsonEncode({
          'ok': false,
          'requires_user_resume': true,
          'error': '执行日志损坏，无法排除重复执行，请用户核验后明确续接。只读检查仍可使用。',
        });
      }
      if (entries.any((e) => e['identity'] == identity)) {
        return jsonEncode({
          'ok': false,
          'already_dispatched': true,
          'error': '同一调用已派发，不重复执行。',
        });
      }
      final entry = <String, dynamic>{
        'identity': identity,
        'conversation': conversation,
        'task': task,
        'agent': agent,
        'request': request,
        'call_id': callId,
        'tool': tool,
        'fingerprint': fingerprint,
        'status': 'started',
        'started_at': DateTime.now().toUtc().toIso8601String(),
      };
      await _persist([...entries, entry]);
      return null;
    });
    if (blocked != null) return blocked;
    Future<void> finish(
      WorkOperationOutcome outcome,
      String? result,
    ) => _transaction(() async {
      final candidate = [
        for (final e in entries)
          if (e['identity'] == identity)
            {
              ...e,
              'status': outcome.name,
              if (result != null)
                'result_hash': sha256.convert(utf8.encode(result)).toString(),
            }
          else
            Map<String, dynamic>.from(e),
      ];
      try {
        await _persist(candidate);
      } catch (_) {
        // The durable started record remains uncertain; never falsely publish completion.
        for (final e in entries) {
          if (e['identity'] == identity) e['status'] = 'unknown';
        }
        rethrow;
      }
    });
    try {
      final result = await operation();
      await finish(
        classify?.call(result) ?? WorkOperationOutcome.completed,
        result,
      );
      return result;
    } catch (_) {
      await finish(WorkOperationOutcome.unknown, null);
      rethrow;
    }
  }

  Future<void> acknowledge(
    String conversation, {
    required Set<String> reviewedIdentities,
    String? reviewedCorruptionDigest,
  }) => _transaction(() async {
    if (corrupt && reviewedCorruptionDigest != corruptionDigest) {
      throw StateError('损坏日志版本未被明确核验，未解除全局执行保护');
    }
    final current = unresolved(
      conversation,
    ).map((e) => e['review_identity'] as String).toSet();
    if (!current.containsAll(reviewedIdentities)) {
      throw StateError('已审阅记录状态改变，请刷新后重新核验');
    }
    final candidate = [
      for (final entry in entries)
        if (entry['conversation'] == conversation &&
            entry['status'] == 'unknown' &&
            reviewedIdentities.contains(_reviewIdentity(entry)))
          {...entry, 'status': 'user_acknowledged'}
        else
          Map<String, dynamic>.from(entry),
    ];
    await _persist(candidate);
    if (corrupt) corrupt = false;
  });
  Future<void> removeConversation(String conversation) =>
      _transaction(() async {
        await _persist(
          entries.where((e) => e['conversation'] != conversation).toList(),
        );
      });
}
