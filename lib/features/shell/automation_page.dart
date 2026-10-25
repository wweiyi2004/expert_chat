import 'package:expert_chat/core/app_toast.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../../state/chat_controller.dart';
import '../../core/prototype_widgets.dart';
import '../../state/work_processes.dart';
import '../remote/remote_automation_panel.dart';
import 'automation_status.dart';
import '../remote/remote_tasks_page.dart';
import '../workbench/processes/work_processes_panel.dart';

final automationHttpClientFactoryProvider = Provider<Dio Function()>(
  (ref) =>
      () => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      ),
);

/// P1 aggregates existing remote triggers and authorized local file hooks.
class AutomationPage extends ConsumerStatefulWidget {
  const AutomationPage({
    super.key,
    this.onOpenNavigation,
    this.shellHeader = false,
  });
  final bool shellHeader;
  final VoidCallback? onOpenNavigation;
  @override
  ConsumerState<AutomationPage> createState() => _AutomationPageState();
}

class _AutomationPageState extends ConsumerState<AutomationPage> {
  List<Map<String, dynamic>> _computers = [];
  String? _error;
  final _createMenuKey = GlobalKey<PopupMenuButtonState<String>>();
  final _remotePanelKeys = <String, GlobalKey<RemoteAutomationPanelState>>{};
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      const storage = FlutterSecureStorage();
      final raw = await storage.read(key: 'remote_host_computers_v1');
      final pair = await storage.read(key: 'remote_host_pair_v1');
      final computers = <String, Map<String, dynamic>>{};
      for (final item in raw == null ? [] : jsonDecode(raw) as List) {
        final record = Map<String, dynamic>.from(item as Map);
        computers[record['url'] as String] = record;
      }
      if (pair != null) {
        final record = Map<String, dynamic>.from(jsonDecode(pair) as Map);
        computers[record['url'] as String] = record;
      }
      if (mounted) {
        ref
            .read(remoteAutomationCountsProvider.notifier)
            .reconcile(computers.keys);
        setState(() {
          _computers = computers.values.toList();
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取已配对电脑，请重新连接');
    }
  }

  Future<void> _remote() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const RemoteTasksPage()));
    await _load();
  }

  void _local(String id) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(
          toolbarHeight: 52,
          title: const Text('本机文件 Hooks', style: TextStyle(fontSize: 15)),
        ),
        body: WorkProcessesPanel(conversationId: id, initialTab: 2),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final hooks = ref.watch(workHooksProvider);
    final state = ref.watch(chatControllerProvider).value;
    final c = PrototypeColors.of(context);
    final phone = MediaQuery.sizeOf(context).width < 840;
    return Scaffold(
      appBar: widget.shellHeader
          ? null
          : AppBar(
              toolbarHeight: 52,
              leading: widget.onOpenNavigation == null
                  ? null
                  : PrototypeIconButton(
                      icon: Icons.menu,
                      onPressed: widget.onOpenNavigation,
                      tooltip: '打开侧边栏',
                    ),
              title: const Text(
                '自动化',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              automaticallyImplyLeading: false,
            ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListenableBuilder(
            listenable: hooks,
            builder: (context, _) => ListView(
              padding: EdgeInsets.fromLTRB(
                phone ? 14 : 24,
                phone ? 14 : 20,
                phone ? 14 : 24,
                phone ? 24 : 32,
              ),
              children: [
                _AutomationHeading(
                  action: PopupMenuButton<String>(
                    key: _createMenuKey,
                    tooltip: '新建自动化',
                    onSelected: (value) {
                      if (value == 'local') {
                        final id = state?.current?.id;
                        if (id != null) _local(id);
                      } else {
                        _remotePanelKeys[value]?.currentState?.createTrigger();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'local',
                        enabled: state?.current?.workMode == true,
                        child: const Text('本机文件 Hook'),
                      ),
                      for (final computer in _computers)
                        PopupMenuItem(
                          value: computer['url'] as String,
                          enabled:
                              _remotePanelKeys[computer['url']]?.currentState !=
                              null,
                          child: Text(
                            '远程触发器 · ${Uri.tryParse(computer['url'] as String)?.host ?? '电脑'}',
                          ),
                        ),
                    ],
                    child: PrototypeButton(
                      label: '＋ 新建',
                      variant: PrototypeButtonVariant.primary,
                      onPressed: () =>
                          _createMenuKey.currentState?.showButtonMenu(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '远程电脑',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: c.faint,
                        ),
                      ),
                    ),
                    PrototypeButton(
                      label: '配对与远程任务',
                      small: true,
                      variant: PrototypeButtonVariant.ghost,
                      onPressed: _remote,
                    ),
                  ],
                ),
                if (_computers.isEmpty || _error != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface,
                      border: Border.all(color: c.line),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '未连接',
                                style: TextStyle(fontSize: 13, color: c.ink),
                              ),
                              Text(
                                _error ?? '连接远程电脑后查看已有触发器',
                                style: TextStyle(fontSize: 12, color: c.muted),
                              ),
                            ],
                          ),
                        ),
                        PrototypeButton(
                          label: '连接',
                          small: true,
                          onPressed: _remote,
                        ),
                      ],
                    ),
                  )
                else
                  for (final computer in _computers)
                    _RemoteAutomationGroup(
                      key: ValueKey(
                        '${computer['url']}:${computer['connectionId']}',
                      ),
                      pair: computer,
                      onReconnect: _remote,
                      panelKey: _remotePanelKeys.putIfAbsent(
                        computer['url'] as String,
                        () => GlobalKey<RemoteAutomationPanelState>(),
                      ),
                    ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '本机工作区 · 文件 Hooks',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: c.faint,
                        ),
                      ),
                    ),
                    PrototypeButton(
                      label: '新建 / 管理',
                      small: true,
                      variant: PrototypeButtonVariant.ghost,
                      onPressed: state?.current?.workMode == true
                          ? () => _local(state!.current!.id)
                          : null,
                    ),
                  ],
                ),
                if (hooks.records.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '先在工作会话中授权本机工作区，再添加固定命令。',
                      style: TextStyle(fontSize: 12, color: c.muted),
                    ),
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
                        for (var i = 0; i < hooks.records.length; i++) ...[
                          if (i > 0) Divider(height: 1, color: c.line),
                          _LocalHookCard(
                            record: hooks.records[i],
                            runtime: hooks,
                            onManage: () => _local(
                              hooks.records[i].definition.conversationId,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RemoteAutomationGroup extends ConsumerStatefulWidget {
  const _RemoteAutomationGroup({
    super.key,
    required this.pair,
    required this.onReconnect,
    required this.panelKey,
  });
  final Map<String, dynamic> pair;
  final VoidCallback onReconnect;
  final GlobalKey<RemoteAutomationPanelState> panelKey;
  @override
  ConsumerState<_RemoteAutomationGroup> createState() =>
      _RemoteAutomationGroupState();
}

class _RemoteAutomationGroupState
    extends ConsumerState<_RemoteAutomationGroup> {
  final _manualEvents = <String, String>{};
  late final Dio _dio;
  bool _connected = false, _loading = true;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _dio = ref.read(automationHttpClientFactoryProvider)();
    _check();
  }

  Future<void> _check() async {
    try {
      await _request('automation');
      if (mounted) {
        setState(() {
          _connected = true;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _connected = false;
          _loading = false;
        });
      }
    }
  }

  Future<dynamic> _request(String path, {Map<String, dynamic>? body}) async {
    final epoch = _epoch;
    final pair = widget.pair;
    final url = pair['url'] as String;
    final base = Uri.parse(url);
    final local = ['localhost', '127.0.0.1', '::1'].contains(base.host);
    if (base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.scheme != 'https' &&
            !(base.scheme == 'http' &&
                (local || pair['protectedTunnel'] == true)))) {
      throw StateError('需要 HTTPS 或受保护的 VPN/SSH 隧道');
    }
    try {
      final result = await _dio.request<dynamic>(
        '${url.replaceFirst(RegExp(r'/+$'), '')}/v1/$path',
        data: body,
        options: Options(
          followRedirects: false,
          method: body == null ? 'GET' : 'POST',
          headers: {'Authorization': 'Bearer ${pair['token']}'},
        ),
      );
      if (!mounted || epoch != _epoch) throw StateError('配对已改变，忽略旧连接结果');
      if (path == 'automation' && result.data is Map) {
        final items = (result.data as Map)['automations'] as List? ?? [];
        ref
            .read(remoteAutomationCountsProvider.notifier)
            .report(url, items.where((item) => item['paused'] != true).length);
      }
      return result.data;
    } catch (_) {
      if (mounted && epoch == _epoch) {
        ref.read(remoteAutomationCountsProvider.notifier).report(url, null);
        setState(() => _connected = false);
      }
      throw StateError('远程电脑未连接或请求失败，请重连后重试');
    }
  }

  @override
  void dispose() {
    _epoch++;
    _dio.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = Uri.tryParse(widget.pair['url'] as String)?.host ?? '远程电脑';
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text('$label · 正在连接…', style: const TextStyle(fontSize: 12)),
      );
    }
    if (!_connected) {
      final c = PrototypeColors.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$label · 未连接',
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ),
            PrototypeButton(
              label: '重连',
              small: true,
              onPressed: () {
                setState(() => _loading = true);
                _check();
              },
            ),
            PrototypeButton(
              label: '管理',
              small: true,
              variant: PrototypeButtonVariant.ghost,
              onPressed: widget.onReconnect,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RemoteAutomationPanel(
        key: widget.panelKey,
        compactListing: true,
        manualEventIds: _manualEvents,
        request: _request,
        hostLabel: label,
        initiallyExpanded: true,
      ),
    );
  }
}

class _LocalHookCard extends StatelessWidget {
  const _LocalHookCard({
    required this.record,
    required this.runtime,
    required this.onManage,
  });
  final WorkHookRecord record;
  final WorkHookRuntime runtime;
  final VoidCallback onManage;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final root = record.definition.root;
    final name =
        root
            .replaceAll('\\', '/')
            .split('/')
            .where((s) => s.isNotEmpty)
            .lastOrNull ??
        '工作区';
    Future<void> run(Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        if (context.mounted) {
          AppToastMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    final status =
        '${record.status} · 上次：${record.lastTriggeredAt ?? '尚未触发'}${record.error.isEmpty ? '' : ' · ${record.error}'}';
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: record.definition.command,
          child: Text(
            record.definition.command,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              fontFamily: 'monospace',
              height: 1.5,
              color: c.ink,
            ),
          ),
        ),
        Tooltip(
          message: status,
          child: Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
        ),
      ],
    );
    final metadata = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        const PrototypeChip(label: '文件变更', tone: PrototypeTone.running),
        PrototypeChip(label: '本机 · $name', maxWidth: 160, tooltip: root),
        const PrototypeChip(label: '沿用原会话权限'),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PrototypeButton(
          label: '立即运行',
          small: true,
          tooltip: runtime.runUnavailableReason(record.definition.id) ?? '立即运行',
          onPressed: () => run(() => runtime.runNow(record.definition.id)),
        ),
        const SizedBox(width: 6),
        PrototypeSwitch(
          value: record.definition.enabled,
          semanticLabel: '启用 ${record.definition.command}',
          onChanged: (v) =>
              run(() => runtime.save(record.definition.copyWith(enabled: v))),
        ),
        PrototypeIconButton(
          icon: Icons.more_horiz,
          onPressed: onManage,
          tooltip: '管理',
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
}

class _AutomationHeading extends StatelessWidget {
  const _AutomationHeading({required this.action});
  final Widget action;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    final title = Text(
      '自动化',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.ink),
    );
    final hint = Text(
      '管理远程触发器与本机文件 Hooks',
      style: TextStyle(fontSize: 12, color: c.muted),
    );
    return LayoutBuilder(
      builder: (context, size) => size.maxWidth >= 600
          ? Row(
              children: [
                title,
                const SizedBox(width: 10),
                Expanded(child: hint),
                action,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [title, const Spacer(), action]),
                const SizedBox(height: 4),
                hint,
              ],
            ),
    );
  }
}
