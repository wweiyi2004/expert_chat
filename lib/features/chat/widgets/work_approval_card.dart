import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/work_approvals.dart';
import '../../../state/work_agents.dart';
import '../../../core/prototype_widgets.dart';

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
    final c = PrototypeColors.of(context);
    String? command;
    try {
      final decoded = jsonDecode(pending.arguments);
      if (decoded is Map && decoded['command'] is String) {
        command = decoded['command'] as String;
      }
    } catch (_) {
      /* Unknown schemas retain their exact original text below. */
    }
    final mono = Theme.of(context).textTheme.bodySmall!.copyWith(
      fontSize: 12,
      height: 1.5,
      fontFamily: 'monospace',
      fontFamilyFallback: const [
        'NotoSansSC',
        'Microsoft YaHei',
        'PingFang SC',
      ],
    );
    final approve = PrototypeButton(
      label: '批准这一次',
      small: true,
      expand: MediaQuery.sizeOf(context).width < 840,
      variant: PrototypeButtonVariant.primary,
      onPressed: () =>
          ref.read(workApprovalsProvider.notifier).decide(pending.id, true),
    );
    final reject = PrototypeButton(
      label: '拒绝',
      small: true,
      expand: MediaQuery.sizeOf(context).width < 840,
      onPressed: () =>
          ref.read(workApprovalsProvider.notifier).decide(pending.id, false),
    );
    return Container(
      key: const ValueKey('work-approval-card'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.confirmationSoft,
        border: Border.all(color: c.confirmation.withValues(alpha: .3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PrototypeChip(
                label: '等待你的批准',
                tone: PrototypeTone.confirmation,
                maxWidth: 300,
                tooltip: pending.tool,
              ),
              Text(
                pending.target,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          if (pending.sourceAgentId != null) ...[
            const SizedBox(height: 6),
            Text(
              '来自子代理：${sourceAgent?.task ?? pending.sourceAgentId}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: c.muted),
            ),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(4),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: SelectableText(
                  command ?? pending.arguments,
                  style: mono,
                ),
              ),
            ),
          ),
          if (pending.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              pending.reason,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: c.muted),
            ),
          ],
          if (command != null)
            _ApprovalRawArguments(text: pending.arguments, style: mono),
          const SizedBox(height: 8),
          if (MediaQuery.sizeOf(context).width < 840)
            Row(
              children: [
                Expanded(child: approve),
                const SizedBox(width: 8),
                Expanded(child: reject),
              ],
            )
          else
            Wrap(spacing: 8, runSpacing: 4, children: [approve, reject]),
        ],
      ),
    );
  }
}

class _ApprovalRawArguments extends StatefulWidget {
  const _ApprovalRawArguments({required this.text, required this.style});
  final String text;
  final TextStyle style;
  @override
  State<_ApprovalRawArguments> createState() => _ApprovalRawArgumentsState();
}

class _ApprovalRawArgumentsState extends State<_ApprovalRawArguments> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      PrototypeButton(
        label: _expanded ? '收起完整参数' : '查看完整参数',
        small: true,
        icon: _expanded ? Icons.expand_less : Icons.expand_more,
        variant: PrototypeButtonVariant.ghost,
        onPressed: () => setState(() => _expanded = !_expanded),
      ),
      if (_expanded)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            child: SelectableText(widget.text, style: widget.style),
          ),
        ),
    ],
  );
}
