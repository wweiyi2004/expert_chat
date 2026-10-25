import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/provider_profile.dart';
import '../../../domain/llm/deepseek_balance_client.dart';
import '../../../domain/llm/llm_provider.dart';

class ProviderPresetPickerDialog extends StatefulWidget {
  const ProviderPresetPickerDialog({super.key});

  @override
  State<ProviderPresetPickerDialog> createState() =>
      _ProviderPresetPickerDialogState();
}

class _ProviderPresetPickerDialogState
    extends State<ProviderPresetPickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text;
    final grouped = <ProviderPresetGroup, List<ProviderPreset>>{
      for (final group in ProviderPresetGroup.values)
        group: [
          for (final preset in ProviderPreset.presets)
            if (preset.group == group && preset.matchesQuery(query)) preset,
        ],
    };
    final total = grouped.values.fold<int>(0, (sum, list) => sum + list.length);

    return AlertDialog(
      title: const Text('从预设添加服务商'),
      content: SizedBox(
        width: 460,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: '搜索厂商、地址或模型',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: total == 0
                  ? Center(
                      child: Text(
                        '没有匹配的预设',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final group in ProviderPresetGroup.values)
                          if (grouped[group]!.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                              child: Text(
                                group.label,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            for (final preset in grouped[group]!)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(preset.name),
                                subtitle: Text(
                                  preset.hint.isEmpty
                                      ? preset.baseUrl
                                      : '${preset.baseUrl}\n${preset.hint}',
                                ),
                                isThreeLine: preset.hint.isNotEmpty,
                                onTap: () => Navigator.pop(context, preset),
                              ),
                          ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class DeepSeekBalanceCard extends ConsumerStatefulWidget {
  const DeepSeekBalanceCard({
    super.key,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  @override
  ConsumerState<DeepSeekBalanceCard> createState() =>
      _DeepSeekBalanceCardState();
}

class _DeepSeekBalanceCardState extends ConsumerState<DeepSeekBalanceCard> {
  DeepSeekBalance? _balance;
  Object? _error;
  var _loading = false;
  CancelToken? _cancel;

  LlmConfig get _config => LlmConfig(
    baseUrl: widget.baseUrl,
    apiKey: widget.apiKey,
    model: widget.model,
  );

  @override
  void initState() {
    super.initState();
    if (widget.apiKey.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void didUpdateWidget(covariant DeepSeekBalanceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey ||
        oldWidget.baseUrl != widget.baseUrl) {
      if (widget.apiKey.trim().isEmpty) {
        _cancel?.cancel();
        setState(() {
          _balance = null;
          _error = null;
          _loading = false;
        });
        return;
      }
      _refresh();
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (widget.apiKey.trim().isEmpty) return;
    _cancel?.cancel();
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final balance = await ref
          .read(deepSeekBalanceClientProvider)
          .fetch(config: _config, cancelToken: cancel);
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _balance = balance;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasKey = widget.apiKey.trim().isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.account_balance_wallet_outlined,
                color: scheme.primary,
              ),
              title: const Text('DeepSeek 余额'),
              subtitle: Text(
                '官方账户可用额度，查询不会消耗 Token',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: IconButton(
                tooltip: '刷新余额',
                onPressed: !hasKey || _loading ? null : _refresh,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ),
            if (!hasKey)
              Text(
                '填写 API Key 后可查询官方账户余额。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else if (_error != null)
              Text(
                '$_error'.replaceFirst('Exception: ', ''),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.error),
              )
            else if (_balance == null)
              Text(
                _loading ? '正在查询余额…' : '点刷新查询官方账户余额。',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else ...[
              if (!_balance!.isAvailable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    '余额不足，暂时无法调用 API。',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: scheme.error),
                  ),
                ),
              for (final info in _balance!.infos) ...[
                if (_balance!.infos.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      info.currencyLabel,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: _UsageMetric(
                        label: '可用',
                        value: info.format(info.totalBalance),
                      ),
                    ),
                    Expanded(
                      child: _UsageMetric(
                        label: '充值',
                        value: info.format(info.toppedUpBalance),
                      ),
                    ),
                    Expanded(
                      child: _UsageMetric(
                        label: '赠金',
                        value: info.format(info.grantedBalance),
                      ),
                    ),
                  ],
                ),
                if (info != _balance!.infos.last) const SizedBox(height: 12),
              ],
              if (_balance!.infos.isEmpty)
                Text(
                  '账户可用，但未返回余额明细。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class ModelUsageCard extends ConsumerWidget {
  const ModelUsageCard({
    super.key,
    required this.endpoint,
    required this.selectedModel,
  });

  final String endpoint;
  final String selectedModel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(modelUsageControllerProvider);
    final usageController = ref.read(modelUsageControllerProvider.notifier);
    final records = usageController.forEndpoint(endpoint);
    final totals = usageController.totals(endpoint: endpoint);
    final selected = usageController.find(
      endpoint: endpoint,
      model: selectedModel,
    );
    final scheme = Theme.of(context).colorScheme;

    Future<void> clearUsage() async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('清除模型用量？'),
          content: Text(
            endpoint.trim().isEmpty
                ? '这会清除本机保存的全部模型用量统计，不会影响聊天记录。'
                : '这会清除当前服务商的模型用量统计，不会影响聊天记录。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清除'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await usageController.clear(
          endpoint: endpoint.trim().isEmpty ? null : endpoint,
        );
      }
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bar_chart_rounded, color: scheme.primary),
              title: const Text('模型用量'),
              trailing: IconButton(
                tooltip: '清除当前服务商用量',
                onPressed: records.isEmpty ? null : clearUsage,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ),
            if (records.isEmpty)
              Text(
                '暂无用量',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: _UsageMetric(
                      label: '请求',
                      value: '${totals.requests}',
                    ),
                  ),
                  Expanded(
                    child: _UsageMetric(
                      label: '输入',
                      value: _formatUsageTokens(totals.inputTokens),
                    ),
                  ),
                  Expanded(
                    child: _UsageMetric(
                      label: '输出',
                      value: _formatUsageTokens(totals.outputTokens),
                    ),
                  ),
                  Expanded(
                    child: _UsageMetric(
                      label: '缓存',
                      value: _formatUsageTokens(totals.cachedInputTokens),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '当前模型：$selectedModel · 缓存命中率 ${(totals.cacheHitRate * 100).round()}%',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (records.length > 1) ...[
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 4),
                for (final record in records)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(record.model),
                    subtitle: Text(
                      '输入 ${_formatUsageTokens(record.inputTokens)} · '
                      '输出 ${_formatUsageTokens(record.outputTokens)} · '
                      '缓存 ${_formatUsageTokens(record.cachedInputTokens)}',
                    ),
                    trailing: Text('${record.requests} 次'),
                  ),
              ],
              if (selected != null && selected.reasoningTokens > 0)
                Text(
                  '当前模型推理 Token：${_formatUsageTokens(selected.reasoningTokens)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageMetric extends StatelessWidget {
  const _UsageMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelSmall),
      const SizedBox(height: 2),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

String _formatUsageTokens(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) {
    final digits = value % 1000 == 0 ? 0 : 1;
    return '${(value / 1000).toStringAsFixed(digits)}K';
  }
  return '$value';
}
