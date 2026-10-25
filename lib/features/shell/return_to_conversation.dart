import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/chat_controller.dart';
import '../../state/work_rounds.dart';
import '../../state/conversation_attention.dart';
import '../../state/conversation_activity.dart';
import '../../state/work_approvals.dart';
import '../../state/work_questions.dart';
import '../chat/widgets/conversation_execution_indicator.dart';
import 'shell_tab.dart';
import '../../core/prototype_widgets.dart';

/// Persistent route home. Opening another destination never changes the session.
class ReturnToConversation extends ConsumerWidget {
  const ReturnToConversation({
    super.key,
    this.onReturn,
    this.navigatorKey,
    this.compact = false,
  });
  final bool compact;
  final Future<bool> Function()? onReturn;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatControllerProvider).value;
    final current = state?.current;
    final approvals = ref.watch(workApprovalsProvider);
    final questions = ref.watch(workQuestionsProvider);
    final unseen = ref.watch(conversationAttentionProvider);
    final active = ref.watch(conversationActiveIdsProvider);
    final others =
        state?.conversations
            .where(
              (c) =>
                  c.id != current?.id &&
                  (active.contains(c.id) || unseen.contains(c.id)),
            )
            .toList() ??
        [];
    Future<bool> back() async {
      if (onReturn != null) return onReturn!();
      if (Navigator.of(context).canPop()) return false;
      ref.read(shellTabProvider.notifier).set(ShellTab.chat);
      return true;
    }

    final waiting =
        approvals.where((a) => a.conversationId == current?.id).length +
        questions.where((q) => q.conversationId == current?.id).length;
    final round = ref.watch(workRoundsProvider)[current?.id];
    final checkpoint = state?.sessionCheckpoints[current?.id];
    final status = current?.workMode != true
        ? ''
        : waiting > 0
        ? '等你批准 / 回答 $waiting 项'
        : round?.paused == true
        ? '已暂停'
        : current != null && active.contains(current.id)
        ? '执行中${round == null ? '' : ' · 第 ${round.used} / ${round.limit} 轮'}'
        : checkpoint?.status == SessionExecutionStatus.failed
        ? '失败'
        : checkpoint?.status == SessionExecutionStatus.interrupted ||
              checkpoint?.status == SessionExecutionStatus.cancelled
        ? '已暂停'
        : unseen.contains(current?.id)
        ? '有新回复'
        : checkpoint?.status == SessionExecutionStatus.completed
        ? '已完成'
        : '';
    final colors = PrototypeColors.of(context);
    return _ReturnSurface(
      compact: compact,
      onReturn: back,
      waiting: waiting > 0,
      child: Row(
        children: [
          if (compact) ...[
            Icon(Icons.arrow_back, size: 16, color: colors.muted),
            const SizedBox(width: 10),
          ],
          if (current != null)
            ConversationExecutionIndicator(conversation: current),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: back,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current?.title ?? '新聊天',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                      color: colors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (status.isNotEmpty)
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        color: waiting > 0 ? colors.confirmation : colors.muted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ),
          if (!compact)
            PrototypeButton(
              label: '回到对话',
              onPressed: back,
              small: true,
              variant: PrototypeButtonVariant.primary,
            ),
          if (others.isNotEmpty)
            Builder(
              builder: (buttonContext) => PrototypeButton(
                label: MediaQuery.sizeOf(context).width < 840
                    ? '${others.length} ▾'
                    : '另有 ${others.length} 个任务 ▾',
                tooltip: '另有 ${others.length} 个任务',
                small: true,
                variant: PrototypeButtonVariant.ghost,
                onPressed: () async {
                  final controller = ref.read(chatControllerProvider.notifier);
                  final returnToChat = back;
                  final menuContext =
                      navigatorKey?.currentState?.overlay?.context ?? context;
                  final wide = MediaQuery.sizeOf(context).width >= 840;
                  String? id;
                  Widget taskTitle(dynamic c) => Row(
                    children: [
                      ConversationExecutionIndicator(conversation: c),
                      const SizedBox(width: 8),
                      Expanded(child: Text(c.title)),
                    ],
                  );
                  if (!wide) {
                    id = await showModalBottomSheet<String>(
                      context: menuContext,
                      builder: (sheetContext) => SafeArea(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final c in others)
                              ListTile(
                                title: taskTitle(c),
                                onTap: () =>
                                    Navigator.of(sheetContext).pop(c.id),
                              ),
                          ],
                        ),
                      ),
                    );
                  } else {
                    final button =
                        buttonContext.findRenderObject() as RenderBox;
                    final overlay =
                        (navigatorKey?.currentState?.overlay ??
                                    Navigator.of(context).overlay)!
                                .context
                                .findRenderObject()
                            as RenderBox;
                    final rect = Rect.fromPoints(
                      overlay.globalToLocal(button.localToGlobal(Offset.zero)),
                      overlay.globalToLocal(
                        button.localToGlobal(
                          button.size.bottomRight(Offset.zero),
                        ),
                      ),
                    );
                    id = await showMenu<String>(
                      context: menuContext,
                      position: RelativeRect.fromRect(
                        rect,
                        Offset.zero & overlay.size,
                      ),
                      items: [
                        for (final c in others)
                          PopupMenuItem(value: c.id, child: taskTitle(c)),
                      ],
                    );
                  }
                  if (id == null || !await returnToChat()) {
                    return;
                  }
                  await controller.selectConversation(id);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ReturnSurface extends StatelessWidget {
  const _ReturnSurface({
    required this.compact,
    required this.onReturn,
    required this.waiting,
    required this.child,
  });
  final bool compact, waiting;
  final Future<bool> Function() onReturn;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = PrototypeColors.of(context);
    return SafeArea(
      top: false,
      bottom: !compact,
      child: Padding(
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Tooltip(
          message: compact ? '回到对话' : '返回原会话',
          child: Material(
            color: colors.surface,
            elevation: compact ? 0 : 1,
            shadowColor: colors.ink.withValues(alpha: .08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(compact ? 999 : 16),
              side: BorderSide(
                color: waiting
                    ? Color.lerp(colors.line, colors.confirmation, .4)!
                    : colors.line,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(compact ? 999 : 16),
              onTap: onReturn,
              child: Padding(
                padding: compact
                    ? const EdgeInsets.fromLTRB(10, 5, 14, 5)
                    : const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
