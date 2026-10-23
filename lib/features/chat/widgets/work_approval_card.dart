import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/work_approvals.dart';
import '../../../state/work_agents.dart';

class WorkApprovalCard extends ConsumerWidget {
  const WorkApprovalCard({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref
        .watch(workApprovalsProvider)
        .where((r) => r.conversationId == conversationId)
        .firstOrNull;
    if (pending == null) return const SizedBox.shrink();
    final sourceAgent = pending.sourceAgentId == null
        ? null
        : ref.watch(workAgentsProvider).record(pending.sourceAgentId!);
    return Card(
      key: const ValueKey('work-approval-card'),
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '请求批准 · ${pending.tool}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (pending.sourceAgentId != null)
              Text(
                '来自子代理：${sourceAgent?.task ?? pending.sourceAgentId}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            Text(pending.target, style: Theme.of(context).textTheme.bodySmall),
            if (pending.reason.isNotEmpty) Text(pending.reason),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: SelectableText(pending.arguments),
              ),
            ),
            Wrap(
              spacing: 12,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  onPressed: () => ref
                      .read(workApprovalsProvider.notifier)
                      .decide(pending.id, false),
                  child: const Text('拒绝'),
                ),
                FilledButton(
                  onPressed: () => ref
                      .read(workApprovalsProvider.notifier)
                      .decide(pending.id, true),
                  child: const Text('批准这一次'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
