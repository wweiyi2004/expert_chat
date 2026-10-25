import '../../../core/application_surface.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/model_context.dart';
import '../../../state/settings_controller.dart';
import '../../../state/work_session_insights.dart';
import '../../../domain/context/context_window_manager.dart';
import '../../../state/model_pricing.dart';
import '../../../state/chat_controller.dart';
import '../../settings/settings_page.dart';
import '../../shell/conversation_return_scope.dart';

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
    final settings = ref.watch(settingsControllerProvider).value;
    final report = ref.watch(
      chatControllerProvider.select(
        (s) => s.value?.contextReports[conversationId],
      ),
    );
    final budget =
        insight?.contextBudgetTokens ??
        report?.inputBudgetTokens ??
        (settings == null
            ? 0
            : effectiveContextPrefs(
                settings,
                settings.config,
              ).inputBudgetTokens);
    final tokens = insight == null
        ? report?.sentTokens ?? 0
        : const ContextWindowManager().estimateMessagesTokens(
                insight.messages,
              ) +
              const ContextWindowManager().estimateTextTokens(
                jsonEncode(insight.tools.map((t) => t.toJson()).toList()),
              );
    final fraction = budget <= 0 ? 0.0 : (tokens / budget).clamp(0.0, 1.0);
    final estimate = insight == null
        ? null
        : estimateWorkCost(insight, ref.watch(modelPricingProvider));
    final cache = insight?.cacheHitRate;
    final cost = insight?.cost;
    final pending = ref
        .watch(chatControllerProvider)
        .value
        ?.pendingSessionConfigurations[conversationId];
    return Tooltip(
      message: '上下文用量 · ${(fraction * 100).round()}%',
      child: IconButton(
        key: const ValueKey('work-context-details'),
        constraints: BoxConstraints.tightFor(
          width: MediaQuery.sizeOf(context).width < 840 ? 44 : 28,
          height: MediaQuery.sizeOf(context).width < 840 ? 44 : 28,
        ),
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          minimumSize: Size.square(
            MediaQuery.sizeOf(context).width < 840 ? 44 : 28,
          ),
          maximumSize: Size.square(
            MediaQuery.sizeOf(context).width < 840 ? 44 : 28,
          ),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (sheet) => SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('上下文与用量', style: Theme.of(sheet).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  Text(
                    '上下文 ${_tokens(tokens)} / ${_tokens(budget)} · ${(fraction * 100).round()}%',
                  ),
                  Text(
                    '丢弃消息 ${report?.droppedMessages ?? 0} 条${report?.summaryInjected == true ? ' · 已注入摘要' : ''}',
                  ),
                  Text(
                    cache == null
                        ? '缓存命中：${insight?.requests.values.any((u) => u != null) == true ? '未提供' : '待统计'}'
                        : '缓存命中 ${(cache * 100).toStringAsFixed(1)}%${insight!.cacheComplete ? '' : '（统计尚未齐全）'}',
                  ),
                  Text(
                    cost != null
                        ? '费用 ${insight!.currency} ${cost.toStringAsFixed(4)}'
                        : estimate != null
                        ? '${estimate.complete ? '估算费用' : '已知用量估算'} ≈${estimate.currency} ${estimate.amount.toStringAsFixed(4)}'
                        : '费用：未提供；设置单价后可估算已知用量',
                  ),
                  if (report != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(report.userFacingNote),
                    ),
                  if (pending?.queued ?? false)
                    Text('设置待生效：${pending!.labels.join('、')}将在当前完整工具轮结束后生效'),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(sheet);
                      _showContext(context, insight, budget, tokens);
                    },
                    icon: const Icon(Icons.data_object),
                    label: const Text('查看实际请求消息与工具'),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(
                        applicationSurfaceRoute<void>(
                          context,
                          (_) => const SettingsPage(
                            initialCategory: SettingsCategory.model,
                          ),
                          protectRoot: false,
                          settings: const RouteSettings(
                            name: conversationSettingsRouteName,
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.tune),
                    label: const Text('用量与单价 · 前往设置 › 模型'),
                  ),
                ],
              ),
            ),
          ),
        ),
        icon: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            value: fraction,
            strokeWidth: 2,
            backgroundColor: Theme.of(context).colorScheme.outlineVariant,
          ),
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
