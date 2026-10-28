import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/task_core/task_acceptance.dart';
import '../data/task_data_backup.dart';
export '../domain/task_core/task_acceptance.dart';

final taskAcceptanceProvider =
    NotifierProvider<TaskAcceptanceStore, Map<String, TaskAcceptance>>(
      TaskAcceptanceStore.new,
    );

class TaskAcceptanceStore extends Notifier<Map<String, TaskAcceptance>> {
  static const storageKey = 'taskAcceptance.v1';
  Future<void> _writes = Future.value();
  Map<String, AcceptanceCriteria> _drafts = {};
  String? storageError;
  Object? get rawStoredValue => ref.read(sharedPrefsProvider).get(storageKey);
  void requireFrozen(String taskId) {
    if (storageError != null) {
      throw StateError(storageError!);
    }
    if (!state.containsKey(taskId)) {
      throw StateError('原任务缺少已固化的验收条件，恢复已阻止；请保留记录并明确创建新任务。');
    }
  }

  AcceptanceCriteria draftCriteriaForConversation(String conversationId) =>
      _drafts[conversationId] ?? AcceptanceCriteria();
  Future<void> saveDraft(String conversationId, AcceptanceCriteria criteria) =>
      _transaction((tasks, drafts) {
        drafts[conversationId] = criteria;
      });
  Future<void> reviseByUser(String taskId, AcceptanceCriteria criteria) =>
      _transaction((tasks, drafts) {
        if (!tasks.containsKey(taskId)) {
          throw StateError('Unknown task');
        }
        tasks[taskId] = TaskAcceptance(
          taskId: taskId,
          conversationId: tasks[taskId]!.conversationId,
          criteria: criteria,
        );
      });
  @override
  Map<String, TaskAcceptance> build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      if (raw == null) {
        return {};
      }
      // Strict validation catches malformed/duplicate records before any state is published.
      TaskDataBackup.acceptance(raw);
      final decoded = jsonDecode(raw);
      final rows = decoded is List
          ? decoded
          : (decoded as Map)['tasks'] as List;
      if (decoded is Map) {
        for (final e in Map<String, dynamic>.from(
          decoded['drafts'] as Map? ?? {},
        ).entries) {
          _drafts[e.key] = AcceptanceCriteria.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
        }
      }
      return {
        for (final j in rows)
          (j as Map)['taskId'] as String: TaskAcceptance.fromJson(
            Map<String, dynamic>.from(j),
          ),
      };
    } catch (error) {
      storageError = '验收存储损坏，原始数据已保留；任务执行与验收已阻止，请先导出原始记录。($error)';
      _drafts = {};
      return {};
    }
  }

  Future<void> freeze(
    String taskId,
    AcceptanceCriteria criteria, {
    String conversationId = '',
    bool requireExisting = false,
  }) => _transaction((tasks, drafts) {
    if (requireExisting && !tasks.containsKey(taskId)) {
      throw StateError('原任务缺少已固化验收条件，不能用默认条件恢复。');
    }
    tasks.putIfAbsent(
      taskId,
      () => TaskAcceptance(
        taskId: taskId,
        conversationId: conversationId,
        criteria: criteria,
      ),
    );
  });
  Future<void> removeConversation(String conversationId) =>
      _transaction((tasks, drafts) {
        drafts.remove(conversationId);
        tasks.removeWhere((id, task) => task.conversationId == conversationId);
      });
  Future<void> update(String taskId, void Function(TaskAcceptance) mutation) =>
      _transaction((tasks, drafts) {
        final task = tasks[taskId];
        if (task == null) {
          throw StateError('Freeze criteria before execution');
        }
        mutation(task);
      });
  Future<void> _transaction(
    void Function(Map<String, TaskAcceptance>, Map<String, AcceptanceCriteria>)
    mutate,
  ) {
    final write = _writes.catchError((Object _) {}).then((_) async {
      if (storageError != null) {
        throw StateError(storageError!);
      }
      final tasks = {
        for (final e in state.entries)
          e.key: TaskAcceptance.fromJson(e.value.toJson()),
      };
      final drafts = {..._drafts};
      mutate(tasks, drafts);
      final raw = jsonEncode({
        'tasks': tasks.values.map((t) => t.toJson()).toList(),
        'drafts': drafts.map((k, v) => MapEntry(k, v.toJson())),
      });
      final prefs = ref.read(sharedPrefsProvider);
      final prior = prefs.getString(storageKey);
      try {
        if (!await prefs.setString(storageKey, raw)) {
          throw StateError('Acceptance persistence failed');
        }
      } catch (_) {
        // Legacy preferences mutate their cache before the platform write succeeds.
        try {
          if (prior == null) {
            await prefs.remove(storageKey);
          } else {
            await prefs.setString(storageKey, prior);
          }
        } catch (_) {}
        rethrow;
      }
      _drafts = drafts;
      state = Map.unmodifiable(tasks);
    });
    _writes = write;
    return write;
  }
}
