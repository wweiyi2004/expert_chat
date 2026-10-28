import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/host/host_client.dart';
import '../../../state/task_plans.dart';
import '../../../state/chat_controller.dart';
import '../../tui_bridge/backend.dart';

Future<void> showTaskPlanReview(BuildContext context, TaskPlan plan) =>
    showDialog<void>(
      context: context,
      builder: (_) => _PlanReview(plan: plan),
    );

class TaskPlanCard extends ConsumerWidget {
  const TaskPlanCard({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(
      taskPlansProvider.select((plans) => plans[conversationId]),
    );
    if (plan == null) return const SizedBox.shrink();
    final root = ref.watch(
      chatControllerProvider.select(
        (s) => s.value?.sessionCheckpoints[conversationId]?.taskState['rootId'],
      ),
    );
    final historical = plan.taskId != null && plan.taskId != root;
    final completed = plan.steps
        .where((step) => step.status == PlanStepStatus.completed)
        .length;
    return ListTile(
      dense: true,
      leading: const Icon(Icons.checklist),
      title: Text(
        '计划 v${plan.revision} · ${historical ? '历史记录' : _status(plan)}',
      ),
      subtitle: Text(
        plan.steps.isEmpty
            ? '方案正文 · 验收单独确认'
            : '$completed / ${plan.steps.length} 个步骤已报告完成 · 验收单独确认',
      ),
      trailing: TextButton(
        onPressed: () => showTaskPlanReview(context, plan),
        child: const Text('查看计划'),
      ),
    );
  }
}

String _status(TaskPlan p) => switch (p.status) {
  TaskPlanStatus.tracking => '进度记录',
  TaskPlanStatus.awaitingApproval => '等待审核',
  TaskPlanStatus.approved => '已批准',
  TaskPlanStatus.cancelled => '已取消',
};

class _PlanReview extends ConsumerStatefulWidget {
  const _PlanReview({required this.plan});
  final TaskPlan plan;
  @override
  ConsumerState<_PlanReview> createState() => _PlanReviewState();
}

class _PlanReviewState extends ConsumerState<_PlanReview> {
  final comment = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    comment.dispose();
    super.dispose();
  }

  Future<void> act(String action) async {
    setState(() {
      busy = true;
      error = null;
    });
    final p = widget.plan;
    final params = <String, dynamic>{
      'session_id': p.conversationId,
      'revision': p.revision,
      'content_hash': p.contentHash,
      'text': comment.text,
    };
    try {
      final client = HostClient.current;
      if (client != null) {
        await client.invoke('plan.$action', params);
        await client.refresh(force: true);
      } else {
        await ControllerBridgeBackend(
          ProviderScope.containerOf(context),
        ).invoke('plan.$action', params);
      }
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plan;
    final current = ref.watch(taskPlansProvider)[p.conversationId];
    final root = ref.watch(
      chatControllerProvider.select(
        (s) =>
            s.value?.sessionCheckpoints[p.conversationId]?.taskState['rootId'],
      ),
    );
    final stale =
        (p.taskId != null && p.taskId != root) ||
        current?.revision != p.revision ||
        current?.contentHash != p.contentHash;
    return AlertDialog(
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('计划 v${p.revision} · ${_status(p)}'),
          if (stale)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '计划已变化，请关闭后重新查看。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                p.goal,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              SelectableText(p.body),
              if (p.criteria.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('验收要求'),
                SelectableText(
                  '${p.criteria['description'] ?? ''}\n检查：${(p.criteria['checkIds'] as List? ?? []).join('、')}\n交付：${(p.criteria['artifactPaths'] as List? ?? []).join('、')}',
                ),
              ],
              const SizedBox(height: 12),
              for (final step in p.steps)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(step.title),
                  subtitle: Text(switch (step.status) {
                    PlanStepStatus.pending => '待开始',
                    PlanStepStatus.running => '进行中',
                    PlanStepStatus.cancelled => '已取消',
                    PlanStepStatus.completed =>
                      step.verified ? '已报告完成 · 工具记录可追溯' : '已报告完成 · 尚无工具证据',
                  }),
                  leading: Icon(
                    step.status == PlanStepStatus.completed
                        ? Icons.check_circle_outline
                        : Icons.circle_outlined,
                  ),
                ),
              if (p.comments.isNotEmpty) ...[
                const Divider(),
                const Text('用户评论'),
                for (final entry in p.comments)
                  SelectableText('v${entry['version']}：${entry['text']}'),
              ],
              if (p.history.isNotEmpty)
                ExpansionTile(
                  title: const Text('历史版本'),
                  children: [
                    for (final previous in p.history.reversed)
                      ListTile(
                        title: Text('v${previous['revision']}'),
                        subtitle: SelectableText(
                          previous['body'] as String? ?? '',
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                controller: comment,
                onChanged: (_) => setState(() {}),
                enabled: !busy && !stale,
                maxLength: 2000,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '修改意见',
                  helperText: '提交意见会产生新版本，需要重新审核',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: busy || stale || p.status == TaskPlanStatus.cancelled
              ? null
              : () => act('cancel'),
          child: const Text('取消计划'),
        ),
        TextButton(
          onPressed: busy || stale || comment.text.trim().isEmpty
              ? null
              : () => act('comment'),
          child: const Text('提交意见'),
        ),
        FilledButton(
          onPressed:
              busy || stale || p.status != TaskPlanStatus.awaitingApproval
              ? null
              : () => act('approve'),
          child: const Text('批准此版本并继续'),
        ),
      ],
    );
  }
}
