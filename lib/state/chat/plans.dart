part of '../chat_controller.dart';

extension _PlanExecution on ChatTools {
  Map<String, dynamic> _planCriteria(String conversation) =>
      _runtimeRef
          .read(
            taskAcceptanceProvider,
          )[_sessionRuns[conversation]?.core?.rootId]
          ?.criteria
          .toJson() ??
      {};
  TaskPlan? _boundPlan(String conversation) {
    final run = _sessionRuns[conversation];
    final plan = _runtimeRef.read(taskPlansProvider)[conversation];
    if (plan == null || run == null) return null;
    // A cancelled plan still constrains its original task. It cannot silently
    // become an unrestricted task because the review was dismissed.
    return plan.taskId == run.core?.rootId && plan.taskId != null ||
            plan.taskId == null &&
                plan.goal.trim() == run.originatingUserGoal.trim()
        ? plan
        : null;
  }

  Future<void> _preparePlanBoundary(
    String conversation,
    CancelToken token,
  ) async {
    final run = _sessionRuns[conversation];
    if (run == null) return;
    var waiting = false;
    try {
      while (_runtimeRef.mounted && !token.isCancelled) {
        var plan = _boundPlan(conversation);
        if (plan == null) {
          run.planId = null;
          run.planRevision = null;
          return;
        }
        if (plan.taskId == null && run.core != null) {
          plan = await _runtimeRef
              .read(taskPlansProvider.notifier)
              .claim(
                conversation,
                run.core!.rootId,
                await _taskTarget(conversation),
              );
        }
        if (plan.status == TaskPlanStatus.cancelled) {
          throw StateError('用户已取消此计划；原任务未继续执行。');
        }
        final target = await _taskTarget(conversation),
            criteria = _planCriteria(conversation);
        if (jsonEncode(plan.target) != jsonEncode(target) ||
            jsonEncode(plan.criteria) != jsonEncode(criteria)) {
          plan = await _runtimeRef
              .read(taskPlansProvider.notifier)
              .reviseBinding(conversation, plan.revision, target, criteria);
        }
        if (!plan.requiresReview || plan.approved) {
          run.planId = plan.id;
          run.planRevision = plan.revision;
          if (waiting) {
            await _checkpointSession(
              run,
              SessionExecutionStatus.running,
              '计划已批准，继续执行',
            );
          }
          return;
        }
        if (!waiting) {
          waiting = true;
          _execution.budget?.waitForApproval();
          await _checkpointSession(
            run,
            SessionExecutionStatus.waiting,
            '等待计划审核',
          );
        }
        final changed = Completer<void>();
        void wake(Object? _, Object? _) {
          if (!changed.isCompleted) changed.complete();
        }

        final acceptance = _runtimeRef.read(taskAcceptanceProvider),
            bindings = _runtimeRef.read(conversationWorkspaceBindingsProvider),
            policies = _runtimeRef.read(sessionPolicyProvider);
        final subscriptions = [
          _runtimeRef.listen(taskPlansProvider, wake),
          _runtimeRef.listen(taskAcceptanceProvider, wake),
          _runtimeRef.listen(conversationWorkspaceBindingsProvider, wake),
          _runtimeRef.listen(sessionPolicyProvider, wake),
        ];
        try {
          // Register before comparing again so an approval between the first
          // read and subscription cannot leave the task parked indefinitely.
          if (!identical(plan, _boundPlan(conversation)) ||
              !identical(
                acceptance,
                _runtimeRef.read(taskAcceptanceProvider),
              ) ||
              !identical(
                bindings,
                _runtimeRef.read(conversationWorkspaceBindingsProvider),
              ) ||
              !identical(policies, _runtimeRef.read(sessionPolicyProvider))) {
            continue;
          }
          await Future.any([
            changed.future,
            token.whenCancel.then<void>((_) {}),
          ]);
        } finally {
          for (final subscription in subscriptions) {
            subscription.close();
          }
        }
      }
      if (token.isCancelled) throw token.cancelError!;
    } finally {
      if (waiting) _execution.budget?.resumeWork();
    }
  }

  Future<String> _executePlanTool(ToolCall call, String conversation) async {
    try {
      final store = _runtimeRef.read(taskPlansProvider.notifier);
      if (call.name == 'work_get_plan') {
        return jsonEncode({
          'plan': _runtimeRef.read(taskPlansProvider)[conversation]?.toJson(),
        });
      }
      if (_sourceAgentId != null) throw StateError('子代理只能读取计划，不能修改主任务计划');
      final args = Map<String, dynamic>.from(
        jsonDecode(call.argumentsJson) as Map,
      );
      final run = _sessionRuns[conversation];
      if (run?.core == null) throw StateError('当前没有可关联的工作任务');
      TaskPlan plan;
      if (call.name == 'work_set_plan') {
        plan = await store.propose(
          conversation: conversation,
          goal: run!.originatingUserGoal,
          body: args['body'] as String,
          titles: (args['steps'] as List).cast<String>(),
          expectedRevision: args['expected_revision'] as int,
          requiresReview:
              _policyFor(conversation).planOnly ||
              (_runtimeRef
                      .read(sessionPolicyProvider)[conversation]
                      ?.planOnly ??
                  false),
          target: await _taskTarget(conversation),
          criteria: _planCriteria(conversation),
          taskId: run.core!.rootId,
        );
      } else {
        if (_boundPlan(conversation) == null) throw StateError('计划不属于当前任务');
        final evidence = (args['evidence'] as List? ?? []).cast<String>();
        final successful = <String>{
          for (final message
              in _s.conversations
                  .where((c) => c.id == conversation)
                  .first
                  .messages)
            if (run!.acceptedTaskIds.contains(message.id) ||
                run.core!.lineage.contains(message.id))
              for (final activity in message.searchActivities)
                if (activity.status == SearchActivityStatus.done &&
                    activity.toolCallId != null)
                  activity.toolCallId!,
        };
        plan = await store.progress(
          conversation,
          args['revision'] as int,
          args['step_id'] as String,
          PlanStepStatus.values.byName(args['status'] as String),
          evidence,
          verified: evidence.isNotEmpty && evidence.every(successful.contains),
        );
      }
      return jsonEncode({
        'ok': true,
        'plan': plan.toJson(),
        'waiting_for_user': plan.status == TaskPlanStatus.awaitingApproval,
      });
    } catch (error) {
      return jsonEncode({'ok': false, 'error': '$error'});
    }
  }
}

extension UserPlanActions on ChatController {
  Future<void> approveTaskPlan(
    String conversation,
    int version,
    String hash,
  ) async {
    final plan = _runtimeRef.read(taskPlansProvider)[conversation];
    if (plan == null || plan.revision != version || plan.contentHash != hash) {
      throw StateError('计划已经变化，请重新查看后批准');
    }
    if (plan.taskId != null &&
        plan.taskId != _sessionRuns[conversation]?.core?.rootId) {
      throw StateError('此计划属于历史任务，请查看当前任务的计划');
    }
    final target = await _taskTarget(conversation);
    final criteria =
        _runtimeRef
            .read(
              taskAcceptanceProvider,
            )[_sessionRuns[conversation]?.core?.rootId]
            ?.criteria
            .toJson() ??
        {};
    if (jsonEncode(plan.criteria) != jsonEncode(criteria)) {
      throw StateError('验收条件已变化，请重新查看计划');
    }
    for (final key in [
      'workspaceId',
      'root',
      'sshProfileId',
      'remoteRoot',
      'scopes',
      'sshTarget',
    ]) {
      if (jsonEncode(plan.target[key]) != jsonEncode(target[key])) {
        throw StateError('工作区或授权范围已改变，请重新生成计划');
      }
    }
    await _runtimeRef
        .read(taskPlansProvider.notifier)
        .approve(conversation, version, hash);
  }
}
