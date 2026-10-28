import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/providers.dart';

final workTaskSteeringProvider = Provider<TaskSteeringStore>(
  (ref) => TaskSteeringStore(
    read: (key) => ref.read(sharedPrefsProvider).getString(key),
    write: (key, value) => ref.read(sharedPrefsProvider).setString(key, value),
  ),
);

class TaskSteeringStore {
  TaskSteeringStore({required this.read, required this.write});
  final String? Function(String) read;
  final Future<bool> Function(String, String) write;
  final _tails = <String, Future<void>>{};
  final _cache = <String, List<Map<String, dynamic>>>{};
  String _key(String conversation) =>
      'taskSteering.v1.${sha256.convert(utf8.encode(conversation))}';
  List<Map<String, dynamic>> snapshot(String conversation) {
    try {
      final cached = _cache.putIfAbsent(
        conversation,
        () => (jsonDecode(read(_key(conversation)) ?? '[]') as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
      return cached.map(Map<String, dynamic>.from).toList();
    } catch (_) {
      throw StateError('用户补充队列损坏；保留原记录，不能确认接收新要求');
    }
  }

  Future<T> _transaction<T>(
    String conversation,
    Future<T> Function() operation,
  ) {
    final next = (_tails[conversation] ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => operation());
    _tails[conversation] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _save(
    String conversation,
    List<Map<String, dynamic>> records,
  ) async {
    final pending = records.where((e) => e['status'] == 'queued').toList();
    final terminal = records.where((e) => e['status'] != 'queued').toList();
    final retained = [
      ...terminal.reversed.take(32).toList().reversed,
      ...pending,
    ];
    if (!await write(_key(conversation), jsonEncode(retained))) {
      throw StateError('用户补充要求未保存，尚未确认接收');
    }
    _cache[conversation] = retained.map(Map<String, dynamic>.from).toList();
  }

  Future<Map<String, dynamic>> enqueue(
    String conversation,
    String task,
    String text,
  ) => _transaction(conversation, () async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 12000) {
      throw ArgumentError('补充要求须为 1–12000 字符');
    }
    final records = snapshot(conversation);
    if (records.where((e) => e['status'] == 'queued').length >= 16) {
      throw StateError('待处理补充要求达到 16 条，请等待下一轮接收');
    }
    final entry = <String, dynamic>{
      'id': const Uuid().v4(),
      'task': task,
      'text': trimmed,
      'status': 'queued',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    await _save(conversation, [...records, entry]);
    return Map.from(entry);
  });
  Future<List<Map<String, dynamic>>> prepare(
    String conversation,
    String task,
    int round,
  ) => _transaction(conversation, () async {
    final records = snapshot(conversation);
    final prepared = <Map<String, dynamic>>[];
    final next = [
      for (final entry in records)
        if (entry['task'] == task && entry['status'] == 'queued')
          {
            ...entry,
            'status': 'context_prepared',
            'round': round,
            'prepared_at': DateTime.now().toUtc().toIso8601String(),
          }
        else
          entry,
    ];
    for (var i = 0; i < records.length; i++) {
      if (records[i]['status'] == 'queued' &&
          next[i]['status'] == 'context_prepared') {
        prepared.add(next[i]);
      }
    }
    if (prepared.isNotEmpty) await _save(conversation, next);
    return prepared;
  });

  /// Serialized with consumption: only a still queued entry can be withdrawn.
  Future<String> withdraw(String conversation, String id) =>
      _transaction(conversation, () async {
        final records = snapshot(conversation);
        final entry = records.where((e) => e['id'] == id).firstOrNull;
        if (entry == null || entry['status'] != 'queued') {
          throw StateError('补充要求已消费或不存在，不能撤回');
        }
        await _save(conversation, [
          for (final value in records)
            if (value['id'] == id) {...value, 'status': 'withdrawn'} else value,
        ]);
        return entry['text'] as String;
      });
  String instructions(String conversation, String task) =>
      snapshot(conversation)
          .where((e) => e['task'] == task && e['status'] == 'context_prepared')
          .map((e) => '【用户补充 #${e['id']}】\n${e['text']}')
          .join('\n\n');
  Future<void> cancelPending(String conversation, String task) =>
      _transaction(conversation, () async {
        final records = snapshot(conversation);
        await _save(conversation, [
          for (final entry in records)
            if (entry['task'] == task && entry['status'] == 'queued')
              {...entry, 'status': 'cancelled'}
            else
              entry,
        ]);
      });
  Future<void> removeConversation(String conversation) => _transaction(
    conversation,
    () async {
      if (!await write(_key(conversation), '[]')) throw StateError('补充要求清理失败');
    },
  );
}
