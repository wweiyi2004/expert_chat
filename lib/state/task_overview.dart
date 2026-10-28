import 'package:riverpod/riverpod.dart';
import 'chat_controller.dart';
import 'work_approvals.dart';
import 'work_questions.dart';
import 'work_rounds.dart';
import 'work_task_runtime.dart';
import 'task_plans.dart';
import 'task_acceptance_provider.dart';

class TaskOverview {
  const TaskOverview(
    this.session,
    this.title,
    this.execution,
    this.acceptance,
    this.rank, {
    this.detail = '',
  });
  final String session, title, execution, acceptance, detail;
  final int rank;
  Map<String, Object?> toJson() => {
    'id': session,
    'title': title,
    'execution': execution,
    'acceptance': acceptance,
    'rank': rank,
    'detail': detail,
  };
}

final taskOverviewProvider = Provider<List<TaskOverview>>((ref) {
  final state = ref.watch(chatControllerProvider).value;
  if (state == null) return [];
  final approvals = ref.watch(workApprovalsProvider),
      questions = ref.watch(workQuestionsProvider);
  final rounds = ref.watch(workRoundsProvider),
      plans = ref.watch(taskPlansProvider);
  final tasks = ref.watch(workTaskRuntimeProvider),
      acceptance = ref.watch(taskAcceptanceProvider);
  final controller = ref.read(chatControllerProvider.notifier);
  final values = <TaskOverview>[];
  final latest = <String, WorkTaskRecord>{};
  for (final record in tasks) {
    final previous = latest[record.conversationId];
    if (previous == null || record.startedAt.isAfter(previous.startedAt)) {
      latest[record.conversationId] = record;
    }
  }
  for (final conversation in state.conversations) {
    if (!conversation.workMode &&
        !state.runningConversationIds.contains(conversation.id)) {
      continue;
    }
    final id = conversation.id, checkpoint = state.sessionCheckpoints[id];
    final root = controller.taskSnapshotFor(id)?['rootId'];
    final plan = plans[id];
    var execution = '未开始', rank = 5;
    if (checkpoint?.status == SessionExecutionStatus.cancelled &&
        !state.runningConversationIds.contains(id)) {
      execution = '已停止';
      rank = 2;
    } else if (questions.any((q) => q.conversationId == id)) {
      execution = '等待回答';
      rank = 0;
    } else if (approvals.any((a) => a.conversationId == id)) {
      execution = '等待工具批准';
      rank = 0;
    } else if (plan?.taskId == root &&
        root != null &&
        plan?.status == TaskPlanStatus.awaitingApproval) {
      execution = '等待计划审核';
      rank = 0;
    } else if (tasks.any(
      (t) => t.conversationId == id && t.status.isActive && t.stopRequested,
    )) {
      execution = '正在停止';
      rank = 1;
    } else if (rounds[id]?.paused == true) {
      execution = '已暂停';
      rank = 2;
    } else if (rounds[id]?.pauseRequested == true &&
        state.runningConversationIds.contains(id)) {
      execution = '已请求暂停，等待工具边界';
      rank = 2;
    } else if (state.runningConversationIds.contains(id)) {
      execution = '执行中';
      rank = 1;
    } else if (checkpoint?.status == SessionExecutionStatus.waiting) {
      execution = '等待后台结果';
      rank = 1;
    } else if (checkpoint?.status == SessionExecutionStatus.interrupted) {
      execution = '已中断，结果需核对';
      rank = 2;
    } else if (checkpoint?.status == SessionExecutionStatus.failed) {
      execution = '执行失败';
      rank = 3;
    } else if (checkpoint?.status == SessionExecutionStatus.cancelled) {
      execution = '已停止';
      rank = 2;
    } else if (checkpoint?.status == SessionExecutionStatus.completed) {
      execution = '本轮执行结束';
      rank = 4;
    }
    final status = acceptance[root]?.status;
    final review = switch (status) {
      TaskAcceptanceStatus.accepted => '已验收',
      TaskAcceptanceStatus.waitingAcceptance => '等待验收',
      TaskAcceptanceStatus.failed => '验收未通过',
      _ => '尚未验收',
    };
    values.add(
      TaskOverview(
        id,
        conversation.title,
        execution,
        review,
        rank,
        detail: switch (rank) {
          0 => '打开会话处理需要你确认的事项',
          1 => latest[id]?.detail ?? '',
          2 => '先核对已有结果和远端状态，再决定是否继续',
          3 => latest[id]?.message ?? '打开会话查看失败原因',
          4 => '查看回复、工具记录与交付结果；验收单独确认',
          _ => '发送要求后开始执行',
        },
      ),
    );
  }
  values.sort((a, b) => a.rank.compareTo(b.rank));
  return values;
});
