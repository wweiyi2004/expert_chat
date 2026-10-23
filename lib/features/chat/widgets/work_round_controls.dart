import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/session_policy.dart';
import '../../../state/work_rounds.dart';
import '../../../state/chat_controller.dart';
import 'settings_field_section.dart';

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
      if (mounted && ModalRoute.of(context)?.isCurrent == true)
        Navigator.of(context).pop();
    } catch (e) {
      if (mounted)
        setState(() {
          saving = false;
          error = '$e';
        });
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
  const WorkRoundControls({super.key, required this.conversationId});
  final String conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(
      workRoundsProvider.select((s) => s[conversationId]),
    );
    if (progress == null) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '工具轮次 ${progress.used}/${progress.limit}${progress.reviewing
                    ? ' · AI 正在评估'
                    : progress.finishing && progress.active
                    ? ' · 正在收尾'
                    : ''}',
                style: style,
              ),
              if (progress.active) ...[
                TextButton(
                  onPressed: progress.finishing
                      ? null
                      : () => ref
                            .read(workRoundsProvider.notifier)
                            .addRounds(conversationId),
                  child: Text('+${progress.step} 轮'),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(chatControllerProvider.notifier).stop(),
                  child: const Text('停止'),
                ),
              ] else
                TextButton(
                  onPressed: () =>
                      showWorkRoundSettings(context, ref, conversationId),
                  child: const Text('轮次设置'),
                ),
            ],
          ),
          if (progress.note.isNotEmpty)
            Text(
              progress.note,
              style: style,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
