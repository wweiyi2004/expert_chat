import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import '../../../core/prototype_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/session_policy.dart';
import '../../../state/work_rounds.dart';
import '../../../state/chat_controller.dart';
import '../../../state/task_acceptance_provider.dart';
import 'settings_field_section.dart';
import 'execution_status_indicator.dart';

Future<void> showWorkRoundSettings(
  BuildContext context,
  WidgetRef ref,
  String conversationId,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _WorkRoundSettingsDialog(conversationId: conversationId),
);

class _WorkRoundSettingsDialog extends ConsumerStatefulWidget {
  const _WorkRoundSettingsDialog({required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<_WorkRoundSettingsDialog> createState() =>
      _WorkRoundSettingsDialogState();
}

class _WorkRoundSettingsDialogState
    extends ConsumerState<_WorkRoundSettingsDialog> {
  late final TextEditingController initial, extension, ahead;
  late bool automatic;
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final policy =
        ref.read(sessionPolicyProvider)[widget.conversationId] ??
        const SessionPolicy();
    initial = TextEditingController(text: '${policy.toolRounds}');
    extension = TextEditingController(text: '${policy.roundExtension}');
    ahead = TextEditingController(text: '${policy.roundReviewAhead}');
    automatic = policy.autoExtendRounds;
  }

  @override
  void dispose() {
    initial.dispose();
    extension.dispose();
    ahead.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final values = [
      int.tryParse(initial.text),
      int.tryParse(extension.text),
      int.tryParse(ahead.text),
    ];
    if (values.any((v) => v == null || v < 1 || v > 1000)) {
      setState(() => error = '请填写 1–1000 的整数');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final latest =
          ref.read(sessionPolicyProvider)[widget.conversationId] ??
          const SessionPolicy();
      await ref
          .read(sessionPolicyProvider.notifier)
          .save(
            widget.conversationId,
            latest.copyWith(
              toolRounds: values[0]!,
              roundExtension: values[1]!,
              roundReviewAhead: values[2]!,
              autoExtendRounds: automatic,
            ),
          );
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: const Text('工作轮次预算'),
      scrollable: true,
      content: SizedBox(
        width: 390,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('一轮是模型发起一批工具调用并收到结果。最终总结不占工具轮次。'),
            for (final field in [
              (initial, '初始轮次'),
              (extension, '每次增加轮次'),
              (ahead, '剩余多少轮时评估'),
            ])
              SettingsFieldSection(
                title: field.$2,
                child: TextField(
                  controller: field.$1,
                  enabled: !saving,
                  keyboardType: TextInputType.number,
                  decoration: settingsControlDecoration,
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('AI 自动判断是否续加'),
              value: automatic,
              onChanged: saving
                  ? null
                  : (value) => setState(() => automatic = value),
            ),
            const SizedBox(height: 8),
            Text(
              '评估使用当前任务模型并计入用量；运行时可手动加轮次或停止。时间和工具次数预算仍独立生效。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}

class WorkRoundControls extends ConsumerWidget {
  const WorkRoundControls({
    super.key,
    required this.conversationId,
    this.onSteer,
    this.readOnly = false,
  });
  final String conversationId;
  final VoidCallback? onSteer;
  final bool readOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      workRoundsProvider.select((s) => s[conversationId]),
    );
    if (progress == null) return const SizedBox.shrink();
    final checkpoint = progress.active
        ? null
        : ref
              .watch(chatControllerProvider)
              .value
              ?.sessionCheckpoints[conversationId];
    final stopped = checkpoint?.status == SessionExecutionStatus.cancelled;
    final interrupted =
        checkpoint?.status == SessionExecutionStatus.interrupted;
    final failed = checkpoint?.status == SessionExecutionStatus.failed;
    final taskId = checkpoint?.taskState['rootId'] as String?;
    final acceptance = taskId == null
        ? null
        : ref.watch(taskAcceptanceProvider)[taskId];
    final acceptanceFailed = acceptance?.status == TaskAcceptanceStatus.failed;
    final awaitingAcceptance =
        acceptance?.status == TaskAcceptanceStatus.waitingAcceptance;
    final style = Theme.of(context).textTheme.bodySmall;
    final compact = MediaQuery.sizeOf(context).width < 840;
    final statusCapsule = ExecutionStatusCapsule(
      status: progress.paused
          ? ExecutionVisualStatus.paused
          : progress.active
          ? ExecutionVisualStatus.running
          : failed || acceptanceFailed
          ? ExecutionVisualStatus.failed
          : stopped || interrupted || awaitingAcceptance
          ? ExecutionVisualStatus.paused
          : ExecutionVisualStatus.completed,
      label: progress.paused
          ? '已暂停'
          : progress.active
          ? '执行中'
          : failed
          ? '执行失败'
          : interrupted
          ? '已中断'
          : stopped
          ? '已停止'
          : acceptanceFailed
          ? '检查未通过'
          : awaitingAcceptance
          ? '等待验收'
          : acceptance?.status == TaskAcceptanceStatus.accepted
          ? '验收通过'
          : '本轮已结束',
    );
    final roundLabel = Tooltip(
      message: progress.note,
      child: Text(
        '第 ${progress.used} / ${progress.limit} 轮',
        style: style?.copyWith(fontSize: 12.5),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final actions = <Widget>[
      if (progress.active && !readOnly) ...[
        PrototypeButton(
          small: true,
          label: progress.paused
              ? '继续'
              : progress.pauseRequested
              ? '取消待暂停'
              : compact
              ? '本轮后暂停'
              : '在本轮结束后暂停',
          onPressed: () => progress.pauseRequested
              ? ref.read(workRoundsProvider.notifier).resume(conversationId)
              : ref
                    .read(workRoundsProvider.notifier)
                    .requestPause(conversationId),
        ),
        PrototypeButton(
          small: true,
          label: '+${progress.step} 轮',
          onPressed: progress.finishing
              ? null
              : () => ref
                    .read(workRoundsProvider.notifier)
                    .addRounds(conversationId),
        ),
        PrototypeButton(
          small: true,
          label: '补充任务',
          onPressed:
              onSteer ??
              () => showDialog<void>(
                context: context,
                builder: (_) =>
                    _WorkSteeringDialog(conversationId: conversationId),
              ),
        ),
        PrototypeButton(
          small: true,
          label: '停止',
          variant: PrototypeButtonVariant.danger,
          onPressed: () => ref
              .read(chatControllerProvider.notifier)
              .stop(conversationId: conversationId),
        ),
      ] else if (!readOnly) ...[
        _ContinueWorkButton(
          conversationId: conversationId,
          rounds: progress.step,
        ),
        PrototypeButton(
          small: true,
          label: '轮次设置',
          onPressed: () => showWorkRoundSettings(context, ref, conversationId),
        ),
      ],
    ];
    final progressBar = SizedBox(
      width: 80,
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: progress.limit <= 0
              ? 0
              : (progress.used / progress.limit).clamp(0.0, 1.0),
          minHeight: 4,
          color: PrototypeColors.of(context).running,
          backgroundColor: PrototypeColors.of(context).line,
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 10 : 20, 0, compact ? 10 : 20, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final status = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              statusCapsule,
              const SizedBox(width: 8),
              roundLabel,
              const SizedBox(width: 8),
              progressBar,
            ],
          );
          if (compact && actions.isNotEmpty) {
            return Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          statusCapsule,
                          const SizedBox(width: 6),
                          Flexible(child: roundLabel),
                        ],
                      ),
                    ],
                  ),
                ),
                actions.first,
                if (progress.active) actions.last,
                IconButton(
                  tooltip: '更多轮次操作',
                  icon: const Icon(Icons.more_horiz),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    showDragHandle: true,
                    builder: (sheet) => SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text('轮次操作'),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: actions
                                  .skip(1)
                                  .take(
                                    actions.length - (progress.active ? 2 : 1),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          final controls = <Widget>[
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              actions[i],
            ],
          ];
          if (constraints.maxWidth >=
                  (progress.paused ||
                          progress.pauseRequested ||
                          !progress.active
                      ? 500
                      : 600) &&
              actions.isNotEmpty) {
            return Row(children: [status, const Spacer(), ...controls]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              status,
              if (actions.isNotEmpty)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: controls),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ContinueWorkButton extends ConsumerStatefulWidget {
  const _ContinueWorkButton({
    required this.conversationId,
    required this.rounds,
  });
  final String conversationId;
  final int rounds;
  @override
  ConsumerState<_ContinueWorkButton> createState() =>
      _ContinueWorkButtonState();
}

class _ContinueWorkButtonState extends ConsumerState<_ContinueWorkButton> {
  bool sending = false;
  Future<void> _continue() async {
    if (sending) return;
    setState(() => sending = true);
    try {
      final accepted = await ref
          .read(chatControllerProvider.notifier)
          .sendWorkContinuation(widget.conversationId, widget.rounds);
      if (!accepted && mounted) {
        AppToastMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能继续任务，请检查模型配置或任务状态。')));
      }
    } catch (error) {
      if (mounted) {
        AppToastMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PrototypeButton(
    small: true,
    onPressed: sending ? null : _continue,
    label: sending ? '正在继续…' : '继续 +${widget.rounds} 轮',
  );
}

class _WorkSteeringDialog extends ConsumerStatefulWidget {
  const _WorkSteeringDialog({required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<_WorkSteeringDialog> createState() =>
      _WorkSteeringDialogState();
}

class _WorkSteeringDialogState extends ConsumerState<_WorkSteeringDialog> {
  final editor = TextEditingController();
  bool saving = false;
  String? receipt, error;
  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  Future<void> send() async {
    setState(() => saving = true);
    try {
      final id = await ref
          .read(chatControllerProvider.notifier)
          .addWorkRequirement(widget.conversationId, editor.text);
      if (mounted) setState(() => receipt = id);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('运行中补充任务'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('当前完整工具轮结束后加入主/子代理请求，不重置任务名额；不会撤销已提交操作。可在此改变方向或补充验收要求。'),
            TextField(
              controller: editor,
              readOnly: receipt != null,
              minLines: 4,
              maxLines: 10,
              maxLength: 12000,
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (receipt != null)
              SelectableText('已持久接收 #$receipt；轮次接收状态可在日志查看。'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: Text(receipt == null ? '取消' : '完成'),
      ),
      if (receipt == null)
        FilledButton(
          onPressed: saving ? null : send,
          child: Text(saving ? '保存中…' : '发送补充要求'),
        ),
    ],
  );
}
