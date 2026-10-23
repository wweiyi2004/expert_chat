import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models.dart';
import '../../../state/chat_controller.dart';
import '../../../state/work_questions.dart';
import '../../../state/work_approvals.dart';
import '../../../state/work_task_runtime.dart';
import '../../../state/work_agents.dart';
import '../../../state/work_processes.dart';
import 'execution_ring.dart';

class ConversationExecutionIndicator extends ConsumerStatefulWidget {
  const ConversationExecutionIndicator({super.key, required this.conversation});
  final Conversation conversation;
  @override
  ConsumerState<ConversationExecutionIndicator> createState() =>
      _ConversationExecutionIndicatorState();
}

class _ConversationExecutionIndicatorState
    extends ConsumerState<ConversationExecutionIndicator> {
  static final _seen = <String, String>{};
  bool _wasRunning = false, _completedUnseen = false;
  @override
  Widget build(BuildContext context) {
    final id = widget.conversation.id;
    final state = ref.watch(chatControllerProvider).value;
    final questions = ref
        .watch(workQuestionsProvider)
        .where((q) => q.conversationId == id)
        .toList();
    final approvals = ref
        .watch(workApprovalsProvider)
        .where((q) => q.conversationId == id)
        .toList();
    final task = ref
        .watch(workTaskRuntimeProvider)
        .where((t) => t.conversationId == id)
        .firstOrNull;
    final agents = ref.watch(workAgentsProvider);
    final processes = ref.watch(workProcessesProvider);
    return ListenableBuilder(
      listenable: Listenable.merge([agents, processes]),
      builder: (context, _) {
        final conversation =
            state?.conversations.where((c) => c.id == id).firstOrNull ??
            widget.conversation;
        final children = agents.records
            .where((a) => a.conversationId == id && !a.external)
            .toList();
        final commands = processes.records
            .where((p) => p.conversationId == id && !p.service)
            .toList();
        final activeChildren = children.where((a) => !a.terminal).length;
        final activeCommands = commands.where((p) => p.active).length;
        final running =
            (state?.isConversationRunning(id) ?? false) ||
            activeChildren > 0 ||
            activeCommands > 0;
        final selected = state?.currentId == id;
        final checkpoint = state?.sessionCheckpoints[id];
        final taskChildren = children.where(
          (a) => checkpoint?.taskId == null || a.taskId == checkpoint!.taskId,
        );
        final taskCommands = commands.where(
          (p) => checkpoint?.taskId == null || p.taskId == checkpoint!.taskId,
        );
        final childFailed = taskChildren.any(
          (a) => a.status == WorkAgentStatus.failed,
        );
        final commandFailed = taskCommands.any(
          (p) => p.status == WorkProcessStatus.failed,
        );
        final childInterrupted = taskChildren.any(
          (a) =>
              a.status == WorkAgentStatus.cancelled ||
              a.status == WorkAgentStatus.interrupted,
        );
        final commandInterrupted = taskCommands.any(
          (p) =>
              p.status == WorkProcessStatus.cancelled ||
              p.status == WorkProcessStatus.interrupted,
        );
        final last = conversation.activePath
            .where((m) => m.role == MessageRole.assistant)
            .lastOrNull;
        final signature =
            '${last?.id}:${last?.content.hashCode}:${checkpoint?.status.name}:${checkpoint?.updatedAt.microsecondsSinceEpoch}';
        _seen.putIfAbsent(id, () => signature);
        if ((_wasRunning && !running || _seen[id] != signature) &&
            !selected &&
            (last != null || children.isNotEmpty || commands.isNotEmpty)) {
          _completedUnseen = true;
        }
        if (selected) {
          _seen[id] = signature;
          _completedUnseen = false;
        }
        _wasRunning = running;
        String source(String? agentId) {
          if (agentId == null) return '';
          final agent = agents.record(agentId);
          return ' · 子代理：${agent?.task ?? agentId}';
        }

        final scheme = Theme.of(context).colorScheme;
        String? label;
        Widget? indicator;
        if (questions.isNotEmpty || approvals.isNotEmpty) {
          label = questions.isNotEmpty
              ? '等待输入${source(questions.first.sourceAgentId)}'
              : '等待批准${source(approvals.first.sourceAgentId)}';
          indicator = Icon(
            Icons.circle,
            size: 8,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.orange.shade300
                : Colors.orange.shade800,
          );
        } else if (running ||
            checkpoint?.status == SessionExecutionStatus.waiting) {
          label = [
            checkpoint?.status == SessionExecutionStatus.waiting
                ? '等待后台任务'
                : '执行中',
            if (activeChildren > 0) '$activeChildren 个子代理',
            if (activeCommands > 0) '$activeCommands 个后台任务',
          ].join(' · ');
          indicator = const ExecutionRing();
        } else if (checkpoint?.status == SessionExecutionStatus.failed ||
            childFailed ||
            commandFailed ||
            (state?.error != null && state?.errorConvoId == id) ||
            (checkpoint == null && task?.status == WorkTaskStatus.failed)) {
          label = childFailed
              ? '子代理执行失败'
              : commandFailed
              ? '后台任务执行失败'
              : '执行失败';
          indicator = Icon(Icons.circle, size: 8, color: scheme.error);
        } else if (childInterrupted ||
            commandInterrupted ||
            checkpoint?.status == SessionExecutionStatus.cancelled ||
            checkpoint?.status == SessionExecutionStatus.interrupted ||
            (checkpoint == null &&
                (task?.status == WorkTaskStatus.cancelled ||
                    task?.status == WorkTaskStatus.interrupted)) ||
            (last?.searchActivities.any(
                  (a) => a.status == SearchActivityStatus.running,
                ) ??
                false)) {
          label = '已中断';
          indicator = Icon(
            Icons.pause_circle_outline,
            size: 15,
            color: scheme.onSurfaceVariant,
          );
        } else if (_completedUnseen ||
            checkpoint?.status == SessionExecutionStatus.completed) {
          label = _completedUnseen ? '已完成 · 未查看' : '已完成';
          indicator = Icon(
            Icons.circle,
            size: 8,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.green.shade300
                : Colors.green.shade700,
          );
        }
        if (indicator == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 6, right: 2),
          child: Tooltip(message: label!, child: indicator),
        );
      },
    );
  }
}
