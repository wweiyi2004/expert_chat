import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/prototype_widgets.dart';

typedef RemoteRequest =
    Future<dynamic> Function(String path, {Map<String, dynamic>? body});

class RemoteAutomationPanel extends StatefulWidget {
  const RemoteAutomationPanel({
    super.key,
    required this.request,
    this.hostLabel = '远程电脑',
    this.initiallyExpanded = false,
    this.manualEventIds,
    this.compactListing = false,
  });
  final String hostLabel;
  final bool compactListing;
  final bool initiallyExpanded;
  final Map<String, String>? manualEventIds;
  final RemoteRequest request;
  @override
  RemoteAutomationPanelState createState() => RemoteAutomationPanelState();
}

class RemoteAutomationPanelState extends State<RemoteAutomationPanel> {
  final _localManualPending = <String, String>{};
  Map<String, String> get _manualPending =>
      widget.manualEventIds ?? _localManualPending;
  final _manualBusy = <String>{};
  int _requestEpoch = 0;
  @override
  void didUpdateWidget(covariant RemoteAutomationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hostLabel != widget.hostLabel ||
        oldWidget.request != widget.request) {
      _requestEpoch++;
      _localManualPending.clear();
      _manualBusy.clear();
      _items = [];
      _environments = [];
      _error = null;
      if (widget.initiallyExpanded) _load();
    }
  }

  Future<void> _runManual(String id) async {
    if (_manualBusy.contains(id)) return;
    final epoch = _requestEpoch;
    final event = _manualPending.putIfAbsent(
      id,
      () => 'manual_${const Uuid().v4()}',
    );
    setState(() => _manualBusy.add(id));
    try {
      await widget.request(
        'webhooks/${Uri.encodeComponent(id)}',
        body: {'eventId': event},
      );
      if (!mounted || epoch != _requestEpoch) return;
      _manualPending.remove(id);
      await _load();
    } catch (e) {
      // Unknown network outcomes retain the id; retry cannot create a duplicate
      // remote task after the first request already reached the host.
      if (mounted && epoch == _requestEpoch) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _manualBusy.remove(id));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initiallyExpanded) _load();
  }

  List<dynamic> _items = [], _environments = [];
  String? _error;
  List<String> _allowedPolicies = ['request'];
  bool _allowAutoBudget = false;
  int _defaultRounds = 20, _roundCeiling = 200;
  String _policyLabel(String value) => switch (value) {
    'full' => '完全访问',
    'assisted' => '模型辅助批准',
    _ => '请求批准',
  };
  String _triggerLabel(String value) => switch (value) {
    'schedule' => '定时',
    'file' => '文件变更',
    'repository' => '仓库提交变更',
    _ => 'Webhook',
  };
  Future<void> _load() async {
    final epoch = _requestEpoch;
    try {
      final data = await widget.request('automation') as Map;
      if (mounted && epoch == _requestEpoch) {
        setState(() {
          _items = data['automations'] as List;
          _allowedPolicies = (data['allowedPolicies'] as List? ?? ['request'])
              .cast<String>();
          _allowAutoBudget = data['allowAutoBudgetExtension'] == true;
          _defaultRounds = data['defaultRoundLimit'] as int? ?? 20;
          _roundCeiling = data['roundCeiling'] as int? ?? 200;
          _environments = data['environments'] as List;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && epoch == _requestEpoch) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _edit({
    Map<String, dynamic>? existing,
    bool environment = false,
  }) async {
    final id = TextEditingController(
      text:
          existing?['id'] as String? ??
          'rule_${DateTime.now().millisecondsSinceEpoch}',
    );
    final goal = TextEditingController(
      text: existing?['goal'] as String? ?? '',
    );
    final path = TextEditingController(
      text: existing?['path'] as String? ?? '',
    );
    final interval = TextEditingController(
      text: '${existing?['intervalSeconds'] ?? 300}',
    );
    final startup = TextEditingController(
      text: existing?['startup'] as String? ?? '',
    );
    final dependencies = TextEditingController(
      text: existing?['dependencies'] as String? ?? '',
    );
    final rounds = TextEditingController(
      text: '${existing?['roundLimit'] ?? _defaultRounds}',
    );
    var policy = existing?['policy'] as String? ?? 'request';
    if (!_allowedPolicies.contains(policy)) policy = 'request';
    var autoBudget = existing?['autoBudgetExtension'] == true;
    var trigger = existing?['trigger'] as String? ?? 'schedule';
    var autoStartModel = existing?['autoStartModel'] == true;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => _AutomationDialogOwner(
        controllers: [id, goal, path, interval, startup, dependencies, rounds],
        builder: (context, setDialogState) => AlertDialog(
          title: Text(environment ? '可复用项目环境' : '自动化触发器'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: id,
                    enabled: existing == null,
                    decoration: const InputDecoration(
                      labelText: '名称标识（英文/数字/下划线）',
                    ),
                  ),
                  if (!environment) ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: policy,
                      decoration: const InputDecoration(labelText: '触发任务的命令权限'),
                      items: [
                        for (final mode in _allowedPolicies)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(_policyLabel(mode)),
                          ),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => policy = value!),
                    ),
                    if (policy == 'full')
                      const Text('完全访问会自动执行此规则任务的命令，须由电脑所有者预先允许。'),
                    TextField(
                      controller: rounds,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '任务模型轮次（最多 $_roundCeiling）',
                      ),
                    ),
                    if (_allowAutoBudget)
                      CheckboxListTile(
                        value: autoBudget,
                        onChanged: (value) =>
                            setDialogState(() => autoBudget = value!),
                        title: const Text('允许有界续轮审查'),
                      ),
                    CheckboxListTile(
                      value: autoStartModel,
                      onChanged: (v) =>
                          setDialogState(() => autoStartModel = v!),
                      title: const Text('触发时自动启动模型'),
                      subtitle: const Text('会使用电脑配置的模型额度；命令仍逐次审批'),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: trigger,
                      items: [
                        for (final type in [
                          'schedule',
                          'file',
                          'repository',
                          'webhook',
                        ])
                          DropdownMenuItem(
                            value: type,
                            child: Text(_triggerLabel(type)),
                          ),
                      ],
                      onChanged: (v) => setDialogState(() => trigger = v!),
                    ),
                    TextField(
                      controller: goal,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '触发后的 Agent 目标',
                      ),
                    ),
                    if (trigger == 'schedule')
                      TextField(
                        controller: interval,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '间隔秒数（至少 30）',
                        ),
                      ),
                    if (trigger == 'file')
                      TextField(
                        controller: path,
                        decoration: const InputDecoration(
                          labelText: '工作目录内现有文件的相对路径',
                        ),
                      ),
                    const Text(
                      '文件与仓库变化稳定两次后触发。触发只排队，模型与命令仍需批准；重复 webhook eventId 不重复排队。仓库触发监视 HEAD 提交变化。',
                    ),
                  ] else ...[
                    TextField(
                      controller: dependencies,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: '依赖与环境说明（供复用参考）',
                      ),
                    ),
                    TextField(
                      controller: startup,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '启动 / 安装命令（使用前逐次审批）',
                      ),
                    ),
                    const Text('环境引用固定在此宿主工作目录，不复制密钥，不自动安装依赖。'),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (save == true) {
      try {
        await widget.request(
          'automation',
          body: {
            'type': environment ? 'environment' : 'automation',
            'item': {
              ...?existing,
              'id': id.text.trim(),
              if (environment) ...{
                'startup': startup.text,
                'dependencies': dependencies.text,
              } else ...{
                'trigger': trigger,
                'goal': goal.text,
                'path': path.text,
                'intervalSeconds': int.tryParse(interval.text) ?? 300,
                'autoStartModel': autoStartModel,
                'policy': policy,
                'roundLimit':
                    int.tryParse(rounds.text.trim()) ?? _defaultRounds,
                'autoBudgetExtension': autoBudget,
              },
            },
          },
        );
        await _load();
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
      }
    }
  }

  void createTrigger() => _edit();
  void createEnvironment() => _edit(environment: true);
  Widget _automationRow(Map<String, dynamic> raw) {
    final c = PrototypeColors.of(context);
    final id = raw['id'] as String;
    final info = InkWell(
      onTap: () => _edit(existing: raw),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: c.ink,
            ),
          ),
          Text(
            raw['goal'] as String? ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.6, color: c.muted),
          ),
          Text(
            '上次：${raw['lastRun'] ?? '尚未触发'}${raw['error'] == null ? '' : ' · ${raw['error']}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
        ],
      ),
    );
    final metadata = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        PrototypeChip(
          label:
              '${_triggerLabel(raw['trigger'] as String)}${raw['trigger'] == 'schedule' && raw['intervalSeconds'] != null ? ' · ${raw['intervalSeconds']}秒' : ''}',
          tone: PrototypeTone.running,
        ),
        PrototypeChip(
          label: '远程 · ${widget.hostLabel}',
          maxWidth: 160,
          tooltip: widget.hostLabel,
        ),
        PrototypeChip(
          label: _policyLabel(raw['policy'] as String? ?? 'request'),
        ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrototypeButton(
          label: _manualBusy.contains(id) ? '请求中' : '立即运行',
          small: true,
          tooltip: '立即运行',
          onPressed: raw['paused'] == true || _manualBusy.contains(id)
              ? null
              : () => _runManual(id),
        ),
        const SizedBox(width: 6),
        PrototypeSwitch(
          value: raw['paused'] != true,
          semanticLabel: '启用 $id',
          onChanged: (enabled) async {
            try {
              await widget.request(
                'automation',
                body: {
                  'item': {...raw, 'paused': !enabled},
                },
              );
              await _load();
            } catch (e) {
              if (mounted) setState(() => _error = e.toString());
            }
          },
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: LayoutBuilder(
        builder: (context, size) => size.maxWidth >= 660
            ? Row(
                children: [
                  Expanded(flex: 3, child: info),
                  const SizedBox(width: 12),
                  Flexible(flex: 4, child: metadata),
                  const SizedBox(width: 12),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  info,
                  const SizedBox(height: 8),
                  metadata,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              ),
      ),
    );
  }

  List<Widget> _contents() {
    final c = PrototypeColors.of(context);
    return [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SelectableText(
            _error!,
            style: TextStyle(fontSize: 12, color: c.confirmation),
          ),
        ),
      Row(
        children: [
          if (!widget.compactListing)
            PrototypeButton(
              label: '添加触发器',
              small: true,
              onPressed: createTrigger,
            ),
          const SizedBox(width: 6),
          PrototypeButton(
            label: '添加环境',
            small: true,
            variant: PrototypeButtonVariant.ghost,
            onPressed: createEnvironment,
          ),
          const Spacer(),
          PrototypeIconButton(
            icon: Icons.refresh,
            onPressed: _load,
            tooltip: '刷新远程自动化',
          ),
        ],
      ),
      if (_items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('还没有触发器', style: TextStyle(fontSize: 12, color: c.muted)),
        )
      else
        Container(
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < _items.length; i++) ...[
                if (i > 0) Divider(height: 1, color: c.line),
                _automationRow(Map<String, dynamic>.from(_items[i] as Map)),
              ],
            ],
          ),
        ),
      if (_environments.isNotEmpty)
        ExpansionTile(
          title: const Text('可复用项目环境', style: TextStyle(fontSize: 13)),
          children: [
            for (final raw in _environments)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => _edit(
                          existing: Map<String, dynamic>.from(raw as Map),
                          environment: true,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              raw['id'] as String,
                              style: const TextStyle(fontSize: 13),
                            ),
                            Text(
                              '${raw['dependencies']}\n${raw['startup']}',
                              style: TextStyle(fontSize: 12, color: c.muted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    PrototypeButton(
                      label: '排队启动',
                      small: true,
                      onPressed: () async {
                        try {
                          await widget.request(
                            'environments/${raw['id']}/start',
                            body: {'id': const Uuid().v4()},
                          );
                        } catch (e) {
                          if (mounted) setState(() => _error = e.toString());
                        }
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => widget.compactListing
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _contents(),
        )
      : ExpansionTile(
          initiallyExpanded: widget.initiallyExpanded,
          title: Text(
            '${widget.hostLabel} · 自动化与可复用环境',
            style: const TextStyle(fontSize: 13),
          ),
          onExpansionChanged: (open) {
            if (open) _load();
          },
          children: _contents(),
        );
}

class _AutomationDialogOwner extends StatefulWidget {
  const _AutomationDialogOwner({
    required this.controllers,
    required this.builder,
  });
  final List<TextEditingController> controllers;
  final StatefulWidgetBuilder builder;
  @override
  State<_AutomationDialogOwner> createState() => _AutomationDialogOwnerState();
}

class _AutomationDialogOwnerState extends State<_AutomationDialogOwner> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      StatefulBuilder(builder: widget.builder);
}
