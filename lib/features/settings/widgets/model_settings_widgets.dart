import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/provider_profile.dart';
import '../../../domain/llm/deepseek_balance_client.dart';
import '../../../domain/llm/llm_provider.dart';

import 'media_api_settings_card.dart';

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

class ProfileSelector extends StatelessWidget {
  const ProfileSelector({
    super.key,
    required this.profiles,
    required this.activeId,
    required this.onSelect,
    required this.onAddPreset,
    required this.onAddCustom,
    required this.onEdit,
    required this.onDelete,
  });

  final List<ProviderProfile> profiles;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<ProviderPreset> onAddPreset;
  final VoidCallback onAddCustom;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  Future<void> _addFromPreset(BuildContext context) async {
    final preset = await pickProviderPreset(context);
    if (preset != null) onAddPreset(preset);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: profiles.any((p) => p.id == activeId)
                    ? activeId
                    : (profiles.isNotEmpty ? profiles.first.id : null),
                decoration: const InputDecoration(labelText: '服务商'),
                items: [
                  for (final p in profiles)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        p.name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                ],
                onChanged: (v) => v == null ? null : onSelect(v),
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: '管理服务商',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                switch (value) {
                  case 'edit':
                    onEdit?.call();
                  case 'delete':
                    onDelete?.call();
                  case 'custom':
                    onAddCustom();
                  case 'preset':
                    await _addFromPreset(context);
                }
              },
              itemBuilder: (context) => [
                if (onEdit != null)
                  const PopupMenuItem(value: 'edit', child: Text('编辑当前服务商')),
                if (onDelete != null)
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      '删除当前服务商',
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'preset', child: Text('+ 从预设添加…')),
                const PopupMenuItem(value: 'custom', child: Text('+ 自定义服务商')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _addFromPreset(context),
              icon: const Icon(Icons.auto_awesome_outlined, size: 16),
              label: const Text('从预设添加'),
            ),
            TextButton(onPressed: onAddCustom, child: const Text('自定义服务商')),
          ],
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
              subtitle: Text(
                '统计服务商返回的真实 Token；仅保存在本机',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: IconButton(
                tooltip: '清除当前服务商用量',
                onPressed: records.isEmpty ? null : clearUsage,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ),
            if (records.isEmpty)
              Text(
                '完成一次模型请求后，这里会显示输入、输出和缓存命中用量。',
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

/// Add/edit dialog for a provider profile (name, base URL, models).
/// Full-page add/edit form for a provider profile (a page, not a modal, so it
/// doesn't occlude the settings behind it).
class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key, this.existing});
  final ProviderProfile? existing;

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _models;
  late final TextEditingController _chatModel;
  late final TextEditingController _reasonerModel;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _baseUrl = TextEditingController(text: e?.baseUrl ?? '');
    _models = TextEditingController(text: e?.models.join(', ') ?? '');
    _chatModel = TextEditingController(text: e?.chatModel ?? '');
    _reasonerModel = TextEditingController(text: e?.reasonerModel ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _models.dispose();
    _chatModel.dispose();
    _reasonerModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '新增服务商' : '编辑服务商'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final preset = await pickProviderPreset(context);
                if (preset == null || !mounted) return;
                setState(() {
                  if (_name.text.trim().isEmpty) _name.text = preset.name;
                  _baseUrl.text = preset.baseUrl;
                  _models.text = preset.models.join(', ');
                  _chatModel.text = preset.chatModel;
                  _reasonerModel.text = preset.reasonerModel;
                });
              },
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('从预设填入地址和模型'),
            ),
          ),
          TextField(
            controller: _baseUrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.example.com/v1',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _models,
            decoration: const InputDecoration(
              labelText: '模型列表（逗号分隔）',
              hintText: 'model-a, model-b',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _chatModel,
            decoration: const InputDecoration(labelText: '默认对话模型'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _reasonerModel,
            decoration: const InputDecoration(
              labelText: '深度思考模型',
              hintText: '没有则与对话模型相同',
              helperText: 'DeepSeek V4 等自带思考开关的模型不会切换，只在当前模型上开启思考',
            ),
          ),
        ],
      ),
    );
  }

  void _save() {
    final models = _models.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final chat = _chatModel.text.trim().isNotEmpty
        ? _chatModel.text.trim()
        : (models.isNotEmpty ? models.first : '');
    final reasoner = _reasonerModel.text.trim().isNotEmpty
        ? _reasonerModel.text.trim()
        : chat;
    final base = widget.existing;
    final profile =
        (base ??
                ProviderProfile(
                  name: '',
                  baseUrl: '',
                  chatModel: '',
                  reasonerModel: '',
                ))
            .copyWith(
              name: _name.text.trim().isEmpty ? '未命名' : _name.text.trim(),
              baseUrl: _baseUrl.text.trim(),
              models: models.isEmpty ? [chat] : models,
              chatModel: chat,
              reasonerModel: reasoner,
            );
    Navigator.of(context).pop(profile);
  }
}

/// Mini chat mock using the selected palette (independent of applied ThemeData
/// timing so the card always previews the chosen seed/accent).
