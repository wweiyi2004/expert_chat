import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/task_overview.dart';
import '../../../state/chat_controller.dart';

Future<void> showTaskOverview(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _TaskOverviewDialog(),
);

class _TaskOverviewDialog extends ConsumerWidget {
  const _TaskOverviewDialog();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(taskOverviewProvider),
        chat = ref.watch(chatControllerProvider).value;
    return AlertDialog(
      title: const Text('任务总览'),
      content: SizedBox(
        width: 720,
        height: 480,
        child: tasks.isEmpty
            ? const Center(child: Text('还没有工作任务'))
            : ListView(
                children: [
                  for (final group in const {
                    0: '需要你处理',
                    1: '执行中',
                    2: '暂停或中断',
                    3: '执行失败',
                    4: '执行结束',
                    5: '未开始',
                  }.entries)
                    if (tasks.any((t) => t.rank == group.key)) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          group.value,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      for (final task in tasks.where(
                        (t) => t.rank == group.key,
                      ))
                        ListTile(
                          title: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${task.execution} · ${task.acceptance}\n${task.detail}',
                          ),
                          onTap: () async {
                            await ref
                                .read(chatControllerProvider.notifier)
                                .selectConversation(task.session);
                            if (context.mounted) Navigator.pop(context);
                          },
                          trailing:
                              chat?.runningConversationIds.contains(
                                    task.session,
                                  ) ==
                                  true
                              ? TextButton(
                                  onPressed: () => ref
                                      .read(chatControllerProvider.notifier)
                                      .stop(conversationId: task.session),
                                  child: const Text('停止'),
                                )
                              : chat
                                        ?.sessionCheckpoints[task.session]
                                        ?.resumeRequired ==
                                    true
                              ? TextButton(
                                  onPressed: () => ref
                                      .read(chatControllerProvider.notifier)
                                      .resumeSessionTask(task.session),
                                  child: const Text('恢复'),
                                )
                              : null,
                        ),
                    ],
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
