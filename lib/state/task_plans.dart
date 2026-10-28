import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/providers.dart';
import '../domain/task_core/task_plan.dart';
export '../domain/task_core/task_plan.dart';

final taskPlansProvider = NotifierProvider<TaskPlans, Map<String, TaskPlan>>(
  TaskPlans.new,
);

class TaskPlans extends Notifier<Map<String, TaskPlan>> {
  Future<void> flush() => _pending;
  static const storageKey = 'taskPlans.v1';
  Future<void> _pending = Future.value();
  String? storageError;
  @override
  Map<String, TaskPlan> build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString(storageKey);
      if (raw == null) return {};
      if (raw.length > 32 * 1024 * 1024) {
        throw const FormatException('Plan store too large');
      }
      final values = jsonDecode(raw) as Map;
      final plans = {
        for (final e in values.entries)
          e.key as String: TaskPlan.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          ),
      };
      if (plans.entries.any((e) => e.key != e.value.conversationId)) {
        throw const FormatException('Invalid plan binding');
      }
      return Map.unmodifiable(plans);
    } catch (_) {
      storageError = '计划存储损坏，原始内容已保留；请先核验恢复。';
      return {};
    }
  }

  Future<TaskPlan> _write(
    String conversation,
    TaskPlan Function(TaskPlan?) change,
  ) {
    final operation = _pending.catchError((Object _) {}).then((_) async {
      if (storageError != null) throw StateError(storageError!);
      final next = change(state[conversation]);
      final checked = TaskPlan.fromJson(next.toJson());
      final all = {...state, conversation: checked};
      final encoded = jsonEncode(all.map((k, v) => MapEntry(k, v.toJson())));
      if (encoded.length > 32 * 1024 * 1024) {
        throw StateError('计划存储已满，请先归档历史会话');
      }
      if (!await ref.read(sharedPrefsProvider).setString(storageKey, encoded)) {
        throw StateError('计划未保存');
      }
      if (ref.mounted) state = Map.unmodifiable(all);
      return checked;
    });
    _pending = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<TaskPlan> propose({
    required String conversation,
    required String goal,
    required String body,
    required List<String> titles,
    required int expectedRevision,
    required bool requiresReview,
    required Map<String, dynamic> target,
    Map<String, dynamic> criteria = const {},
    String? taskId,
  }) => _write(conversation, (previous) {
    if ((previous?.revision ?? 0) != expectedRevision) {
      throw StateError('计划版本已变化，请重新读取后修改');
    }
    if (body.trim().isEmpty ||
        body.length > 32000 ||
        titles.length > 32 ||
        titles.any((t) => t.trim().isEmpty || t.length > 500)) {
      throw ArgumentError('计划内容或步骤超限');
    }
    final sameTask = previous?.taskId == taskId && previous?.goal == goal;
    final review =
        requiresReview || sameTask && previous?.requiresReview == true;
    final history = previous == null
        ? <Map<String, dynamic>>[]
        : [
            ...previous.history,
            previous.toJson()..remove('history'),
          ].reversed.take(20).toList().reversed.toList();
    return TaskPlan(
      id: sameTask ? previous!.id : const Uuid().v4(),
      conversationId: conversation,
      revision: (previous?.revision ?? 0) + 1,
      goal: goal,
      body: body,
      steps: [
        for (final title in titles)
          if (sameTask &&
              previous!.steps.where((s) => s.title == title.trim()).length ==
                  1 &&
              titles.where((t) => t.trim() == title.trim()).length == 1)
            previous.steps.firstWhere((s) => s.title == title.trim())
          else
            ...TaskPlan.stepsFromTitles([title]),
      ],
      status: review
          ? TaskPlanStatus.awaitingApproval
          : TaskPlanStatus.tracking,
      requiresReview: review,
      target: target,
      taskId: taskId,
      criteria: criteria,
      comments: sameTask ? previous!.comments : [],
      history: history,
    );
  });
  Future<TaskPlan> reviseBinding(
    String conversation,
    int revision,
    Map<String, dynamic> target,
    Map<String, dynamic> criteria,
  ) => _write(conversation, (old) {
    if (old == null || old.revision != revision) throw StateError('计划版本已变化');
    return old.replace({
      'target': target,
      'criteria': criteria,
      'revision': revision + 1,
      'approvedRevision': null,
      'approvedBy': null,
      'status': old.requiresReview ? 'awaitingApproval' : 'tracking',
      'history': [
        ...old.history,
        old.toJson()..remove('history'),
      ].reversed.take(20).toList().reversed.toList(),
    });
  });
  Future<TaskPlan> comment(
    String conversation,
    int revision,
    String text, {
    String? stepId,
  }) => _write(conversation, (old) {
    if (old == null || old.revision != revision) throw StateError('计划版本已变化');
    if (text.trim().isEmpty || text.length > 2000) {
      throw ArgumentError('评论须为 1–2000 字符');
    }
    if (stepId != null && !old.steps.any((s) => s.id == stepId)) {
      throw StateError('步骤已不存在');
    }
    return old.replace({
      'revision': revision + 1,
      'approvedRevision': null,
      'approvedBy': null,
      'status': old.requiresReview ? 'awaitingApproval' : 'tracking',
      'comments': [
        ...old.comments,
        {
          'id': const Uuid().v4(),
          'version': revision,
          'stepId': stepId,
          'text': text.trim(),
          'author': 'user',
        },
      ].reversed.take(100).toList().reversed.toList(),
    });
  });
  Future<TaskPlan> approve(String conversation, int revision, String hash) =>
      _write(conversation, (old) {
        if (old == null ||
            old.revision != revision ||
            old.contentHash != hash ||
            old.status == TaskPlanStatus.cancelled) {
          throw StateError('计划已改变，旧批准未生效');
        }
        return old.replace({
          'status': 'approved',
          'requiresReview': true,
          'approvedRevision': revision,
          'approvedBy': 'user',
        });
      });
  Future<TaskPlan> cancel(String conversation, int revision) => _write(
    conversation,
    (old) {
      if (old == null || old.revision != revision) throw StateError('计划版本已变化');
      return old.replace({
        'status': 'cancelled',
        'approvedRevision': null,
        'approvedBy': null,
      });
    },
  );
  Future<TaskPlan> claim(
    String conversation,
    String taskId,
    Map<String, dynamic> target,
  ) => _write(conversation, (old) {
    if (old == null || old.taskId != null) throw StateError('计划已绑定任务');
    for (final key in [
      'workspaceId',
      'root',
      'sshProfileId',
      'remoteRoot',
      'scopes',
      'sshTarget',
      'approval',
      'network',
    ]) {
      if (old.target.isNotEmpty &&
          jsonEncode(old.target[key]) != jsonEncode(target[key])) {
        throw StateError('计划工作区或权限已改变');
      }
    }
    return old.replace({'taskId': taskId, 'target': target});
  });
  Future<TaskPlan> progress(
    String conversation,
    int revision,
    String stepId,
    PlanStepStatus status,
    List<String> evidence, {
    required bool verified,
  }) => _write(conversation, (old) {
    if (old == null ||
        old.revision != revision ||
        old.status == TaskPlanStatus.awaitingApproval ||
        old.status == TaskPlanStatus.cancelled) {
      throw StateError('当前计划不可更新进度');
    }
    if (!old.steps.any((s) => s.id == stepId) || evidence.length > 32) {
      throw ArgumentError('步骤或证据无效');
    }
    return old.replace({
      'steps': [
        for (final step in old.steps)
          if (step.id == stepId)
            PlanStep(
              id: step.id,
              title: step.title,
              status: status,
              evidence: evidence,
              verified: verified,
            ).toJson()
          else
            step.toJson(),
      ],
    });
  });
}
