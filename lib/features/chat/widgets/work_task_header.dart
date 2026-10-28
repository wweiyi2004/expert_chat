import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/prototype_widgets.dart';
import '../../../state/chat_controller.dart';
import '../../../state/task_overview.dart';
import '../../../state/task_plans.dart';
import '../../../state/work_rounds.dart';
import 'chat_workspace_options.dart';
import 'task_plan_card.dart';
import 'chat_work_mode_switch.dart';

/// One task heading owns the desktop's status and primary actions.
class WorkTaskHeader extends ConsumerWidget implements PreferredSizeWidget {
  const WorkTaskHeader({
    super.key,
    required this.conversationId,
    required this.title,
    required this.onOpen,
    required this.actions,
    this.onExpandSidebar,
    required this.onModeChanged,
    required this.onAttention,
  });
  final String conversationId, title;
  final ValueChanged<int> onOpen;
  final List<Widget> actions;
  final VoidCallback? onExpandSidebar;
  final ValueChanged<bool>? onModeChanged;
  final VoidCallback onAttention;
  @override
  Size get preferredSize => const Size.fromHeight(152);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = PrototypeColors.of(context);
    final overview = ref
        .watch(taskOverviewProvider)
        .where((v) => v.session == conversationId)
        .firstOrNull;
    final execution = overview?.execution ?? '未开始';
    final label = const ['等待回答', '等待工具批准', '等待计划审核'].contains(execution)
        ? '等你确认'
        : execution == '本轮执行结束'
        ? '本轮完成'
        : execution;
    final progress = ref.watch(workRoundsProvider)[conversationId];
    final running =
        ref
            .watch(chatControllerProvider)
            .value
            ?.runningConversationIds
            .contains(conversationId) ==
        true;
    final plan = ref.watch(taskPlansProvider)[conversationId];
    final waitingPlan = execution == '等待计划审核' && plan != null;
    final waitingAction = execution == '等待工具批准' || execution == '等待回答';
    final needsAttention = waitingPlan || waitingAction || execution == '执行失败';
    final statusColor = needsAttention ? colors.confirmation : colors.accent;
    final statusBackground = needsAttention
        ? colors.confirmationSoft
        : colors.accentSoft;
    final detail = switch (execution) {
      '已停止' => '任务已结束，可继续提出新的要求',
      '未开始' => '描述目标后开始工作',
      '本轮执行结束' => '查看结果，或继续补充要求',
      '等待计划审核' => '查看计划后决定是否执行',
      '等待工具批准' => '有一项操作需要你批准',
      '等待回答' => '有一个问题需要你回答',
      '等待后台结果' => '正在等待命令或子任务完成',
      _ => overview?.detail ?? '',
    };
    return Container(
      key: const ValueKey('desktop-task-header'),
      padding: const EdgeInsets.fromLTRB(24, 12, 18, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onExpandSidebar != null)
                PrototypeIconButton(
                  icon: Icons.menu,
                  tooltip: '展开侧栏',
                  onPressed: onExpandSidebar,
                ),
              SizedBox(
                width: 190,
                child: ChatWorkspaceBar(
                  conversationId: conversationId,
                  busy: running,
                  plain: true,
                ),
              ),
              const Spacer(),
              ChatWorkModeSwitch(workMode: true, onChanged: onModeChanged),
              if (plan != null)
                TextButton.icon(
                  onPressed: () => showTaskPlanReview(context, plan),
                  icon: const Icon(Icons.checklist, size: 16),
                  label: const Text('计划'),
                ),
              ...actions,
            ],
          ),
          const SizedBox(height: 7),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: statusBackground,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: statusColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ),
              if (waitingAction)
                PrototypeButton(
                  small: true,
                  label: '处理确认',
                  onPressed: onAttention,
                ),
              if (running && !waitingPlan && !waitingAction) ...[
                PrototypeButton(
                  small: true,
                  label: progress?.paused == true
                      ? '继续'
                      : progress?.pauseRequested == true
                      ? '等待暂停'
                      : '暂停',
                  onPressed: progress == null || progress.pauseRequested
                      ? null
                      : () => progress.paused
                            ? ref
                                  .read(workRoundsProvider.notifier)
                                  .resume(conversationId)
                            : ref
                                  .read(workRoundsProvider.notifier)
                                  .requestPause(conversationId),
                ),
                PrototypeIconButton(
                  icon: Icons.stop_circle_outlined,
                  tooltip: '停止当前任务',
                  onPressed: () => ref
                      .read(chatControllerProvider.notifier)
                      .stop(conversationId: conversationId),
                ),
              ],
              if (waitingPlan)
                PrototypeButton(
                  small: true,
                  label: '查看计划',
                  onPressed: () => showTaskPlanReview(context, plan),
                ),
              const SizedBox(width: 8),
              for (final entry in const [(0, '文件'), (4, '成果'), (6, '代理')])
                Padding(
                  padding: const EdgeInsets.only(left: 5),
                  child: PrototypeButton(
                    key: ValueKey('task-open-${entry.$1}'),
                    small: true,
                    label: entry.$2,
                    onPressed: () => onOpen(entry.$1),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
