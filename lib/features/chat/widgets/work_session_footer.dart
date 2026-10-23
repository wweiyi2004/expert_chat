import 'dart:convert';
import '../../../state/model_context.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/desktop_providers.dart';
import '../../../domain/context/context_window_manager.dart';
import '../../../state/settings_controller.dart';
import '../../../state/work_session_insights.dart';
import 'chat_workspace_options.dart';
import 'execution_ring.dart';
import '../../../state/model_pricing.dart';
import '../../../state/session_policy.dart';
import 'model_pricing_dialog.dart';
import '../../workbench/workspace_workbench_page.dart';
import '../../../state/work_task_runtime.dart';
import '../../../state/work_approvals.dart';
import '../../../state/work_questions.dart';
import '../../../state/work_rounds.dart';
import '../../../state/chat_controller.dart';

class WorkSessionFooter extends ConsumerWidget {
  const WorkSessionFooter({
    super.key,
    required this.conversationId,
    required this.busy,
    this.workMode = true,
  });
  final String conversationId;
  final bool busy;
  final bool workMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insight = ref.watch(
      workSessionInsightsProvider.select((s) => s[conversationId]),
    );
    final currentSettings = ref.watch(settingsControllerProvider).value;
    final budget =
        insight?.contextBudgetTokens ??
        (currentSettings == null
            ? 0
            : effectiveContextPrefs(
                currentSettings,
                currentSettings.config,
              ).inputBudgetTokens);
    final tokens = insight == null
        ? 0
        : const ContextWindowManager().estimateMessagesTokens(
                insight.messages,
              ) +
              const ContextWindowManager().estimateTextTokens(
                jsonEncode(insight.tools.map((t) => t.toJson()).toList()),
              );
    // Keep the reported ratio visible while subsequent requests are running.
    final cacheRate = insight?.cacheHitRate;
    final cache = cacheRate != null
        ? '${(cacheRate * 100).toStringAsFixed(1)}%${insight!.cacheComplete ? '' : '*'}'
        : insight?.requests.values.any((u) => u != null) == true
        ? '未提供'
        : '待统计';
    final cost = insight?.cost;
    final rates = ref.watch(modelPricingProvider);
    final estimate = insight == null ? null : estimateWorkCost(insight, rates);
    final settings = ref.watch(settingsControllerProvider).value;
    final taskStatus = ref.watch(
      workTaskRuntimeProvider.select(
        (records) => records
            .where((r) => r.conversationId == conversationId)
            .firstOrNull
            ?.status,
      ),
    );
    final awaitingApproval = ref.watch(
      workApprovalsProvider.select(
        (requests) => requests.any((r) => r.conversationId == conversationId),
      ),
    );
    final running = ref.watch(
      chatControllerProvider.select(
        (value) => value.value?.isConversationRunning(conversationId) ?? false,
      ),
    );
    final phase = ref.watch(
      workRoundsProvider.select(
        (states) => (
          states[conversationId]?.reviewing ?? false,
          states[conversationId]?.finishing ?? false,
        ),
      ),
    );
    final awaitingAnswer = ref
        .watch(workQuestionsProvider)
        .any((q) => q.conversationId == conversationId);
    final checkpoint = ref
        .watch(chatControllerProvider)
        .value
        ?.sessionCheckpoints[conversationId];
    final waiting = checkpoint?.status == SessionExecutionStatus.waiting;
    final statusLabel = awaitingAnswer
        ? '等待回答'
        : awaitingApproval
        ? '等待批准'
        : running
        ? phase.$1
              ? '评估续轮'
              : phase.$2
              ? '收尾中'
              : '执行中'
        : waiting
        ? '等待后台任务'
        : checkpoint?.status == SessionExecutionStatus.failed
        ? '执行失败'
        : checkpoint?.status == SessionExecutionStatus.cancelled
        ? '已停止'
        : checkpoint?.status == SessionExecutionStatus.completed
        ? '已完成'
        : taskStatus?.label ?? '就绪';
    final pending = ref
        .watch(chatControllerProvider)
        .value
        ?.pendingSessionConfigurations[conversationId];
    final colors = Theme.of(context).colorScheme;
    final statusColor = awaitingAnswer || awaitingApproval
        ? (Theme.of(context).brightness == Brightness.dark
              ? Colors.orange.shade300
              : Colors.orange.shade800)
        : checkpoint?.status == SessionExecutionStatus.failed
        ? colors.error
        : !running && checkpoint?.status == SessionExecutionStatus.completed
        ? (Theme.of(context).brightness == Brightness.dark
              ? Colors.green.shade300
              : Colors.green.shade700)
        : colors.primary;
    final metrics = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SessionMetric(
          key: const ValueKey('work-context-details'),
          icon: Icons.data_usage_rounded,
          label: insight == null
              ? '上下文 · 待发送'
              : '上下文 ${_tokens(tokens)} / ${_tokens(budget)}',
          onTap: () => _showContext(context, insight, budget, tokens),
        ),
        _SessionMetric(
          icon: Icons.bolt_rounded,
          label: '缓存 $cache',
          tooltip:
              '缓存命中率。已有 ${insight?.cacheReportedRequests ?? 0}/${insight?.requests.length ?? 0} 次请求返回统计；* 表示数据尚未齐全，缺失数据不按零计算。',
        ),
        _SessionMetric(
          icon: Icons.toll_outlined,
          label: cost != null
              ? '${insight!.currency} ${cost.toStringAsFixed(4)}'
              : estimate != null
              ? '${estimate.complete ? '估算' : '已知用量'} ≈${estimate.currency} ${estimate.amount.toStringAsFixed(4)}'
              : '费用 · 设置单价',
          tooltip: '配置模型单价；估算仅包含已知用量。',
          onTap: () => showModelPricing(context, ref, {
            ...?insight?.pricingKeys.values,
            if (settings != null)
              modelPricingKey(
                settings.baseUrl,
                insight?.model.isNotEmpty == true
                    ? insight!.model
                    : settings.model,
              ),
          }),
        ),
        _SessionMetric(
          key: const ValueKey('open-workbench'),
          icon: Icons.circle,
          leading: running || waiting
              ? ExecutionRing(size: 12, color: statusColor)
              : null,
          label: statusLabel,
          color: statusColor,
          onTap: !workMode
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        WorkspaceWorkbenchPage(conversationId: conversationId),
                  ),
                ),
        ),
        if (pending?.queued ?? false)
          _SessionMetric(
            icon: Icons.schedule_rounded,
            label: '设置待生效',
            color: colors.tertiary,
            tooltip: '${pending!.labels.join('、')}将在当前完整工具轮结束后生效',
          ),
      ],
    );
    final supported =
        workMode &&
        (ref.watch(desktopWorkspaceHostProvider).supported ||
            (ref
                    .watch(sessionPolicyProvider)[conversationId]
                    ?.sshProfileId
                    .isNotEmpty ??
                false));
    return Padding(
      key: const ValueKey('work-session-footer'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (supported) ...[
              ChatWorkspaceBar(conversationId: conversationId, busy: busy),
              const SizedBox(height: 4),
            ],
            metrics,
          ],
        ),
      ),
    );
  }

  String _tokens(int value) =>
      value >= 1000 ? '${(value / 1000).toStringAsFixed(1)}K' : '$value';

  void _showContext(
    BuildContext context,
    WorkSessionInsights? insight,
    int budget,
    int tokens,
  ) {
    const encoder = JsonEncoder.withIndent('  ');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 900),
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .78,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: const Text('最近一次请求的上下文'),
                subtitle: Text(
                  insight == null
                      ? '发送工作任务后，可在这里查看实际请求的消息和工具定义。'
                      : '${insight.model} · 估算 $tokens / $budget tokens\n本次打开软件累计：输入 ${insight.inputTokens}，输出 ${insight.outputTokens}。快照未写入历史记录。',
                ),
                trailing: IconButton(
                  tooltip: '关闭上下文',
                  onPressed: () => Navigator.pop(sheet),
                  icon: const Icon(Icons.close),
                ),
              ),
              if (insight != null)
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    itemCount: insight.messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index == insight.messages.length) {
                        return ExpansionTile(
                          title: Text('可用工具 · ${insight.tools.length}'),
                          children: [
                            SelectableText(
                              encoder.convert(
                                insight.tools.map((t) => t.toJson()).toList(),
                              ),
                            ),
                          ],
                        );
                      }
                      final message = insight.messages[index];
                      return ExpansionTile(
                        title: Text('${index + 1}. ${message.role.name}'),
                        subtitle: Text(
                          message.content,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SelectableText(message.content),
                                if (message.reasoningContent?.isNotEmpty ??
                                    false)
                                  SelectableText(message.reasoningContent!),
                                if (message.toolCalls.isNotEmpty)
                                  SelectableText(
                                    encoder.convert(
                                      message.toolCalls
                                          .map((t) => t.toOpenAiJson())
                                          .toList(),
                                    ),
                                  ),
                                if (message.hasImageParts)
                                  Text(
                                    '图片附件 ${message.imageDataUrls.length + message.imageFileIds.length} 个（不展开二进制数据）',
                                  ),
                                if (message.responseOutputItems.isNotEmpty)
                                  Text(
                                    '含 ${message.responseOutputItems.length} 项协议续传内容',
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionMetric extends StatelessWidget {
  const _SessionMetric({
    super.key,
    required this.icon,
    required this.label,
    this.tooltip,
    this.onTap,
    this.color,
    this.leading,
  });
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final Widget? leading;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = color ?? colors.onSurfaceVariant;
    final pill = Material(
      color: color?.withValues(alpha: .09) ?? colors.surface,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading ??
                  Icon(
                    icon,
                    size: icon == Icons.circle ? 7 : 13,
                    color: foreground,
                  ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}
