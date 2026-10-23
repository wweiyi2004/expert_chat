import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/desktop_providers.dart';
import '../../domain/desktop/workspace_host.dart';
import '../../domain/desktop/workspace_tools.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../state/session_policy.dart';
import '../../state/research_terminal_controller.dart';
import '../../state/chat_controller.dart';
import '../../state/work_changes.dart';
import 'changes/work_changes_page.dart';
import 'git/git_workspace_page.dart';
import 'runtime/work_task_panel.dart';
import 'runtime/workspace_command_panel.dart';
import 'browser/workspace_browser.dart';
import 'files/workspace_file_tab.dart';
import 'agents/work_agents_panel.dart';
import 'processes/work_processes_panel.dart';
import 'logs/work_runtime_logs_panel.dart';
import 'files/delivered_file_tab.dart';
import '../chat/widgets/work_round_controls.dart';
import '../chat/widgets/work_approval_card.dart';

class WorkspaceWorkbenchPage extends ConsumerStatefulWidget {
  const WorkspaceWorkbenchPage({
    super.key,
    required this.conversationId,
    this.embedded = false,
    this.initialTab = 4,
    this.onClose,
    this.onToggleExpanded,
    this.expanded = false,
    this.initialDelivery,
    this.deliveryRequestId = 0,
  });
  final WorkFileChange? initialDelivery;
  final int deliveryRequestId;
  final bool embedded;
  final bool expanded;
  final VoidCallback? onToggleExpanded;
  final int initialTab;
  final VoidCallback? onClose;
  final String conversationId;
  @override
  ConsumerState<WorkspaceWorkbenchPage> createState() =>
      _WorkspaceWorkbenchPageState();
}

class _WorkbenchTab {
  const _WorkbenchTab(this.id, this.kind, {this.path, this.delivery});
  final WorkFileChange? delivery;
  final int id, kind;
  final String? path;
}

class _WorkspaceWorkbenchPageState
    extends ConsumerState<WorkspaceWorkbenchPage> {
  final _tabs = <_WorkbenchTab>[];
  final _fileControllers = <int, FileTabController>{};
  final _dirtyFiles = <int>{};
  final _tabScroll = ScrollController();
  int _nextTabId = 0;
  int? _activeTab;
  bool _allowPop = false;
  static const _labels = [
    '工作区文件',
    '浏览器',
    '终端',
    '改动',
    '任务',
    '',
    'Agents',
    'Services',
    '日志',
  ];
  static const _icons = [
    Icons.folder_open_outlined,
    Icons.language,
    Icons.terminal,
    Icons.difference_outlined,
    Icons.task_alt,
    Icons.insert_drive_file_outlined,
    Icons.account_tree_outlined,
    Icons.dns_outlined,
    Icons.receipt_long_outlined,
  ];
  final _token = CancelToken();
  late final Future<WorkToolSession> _opening = _openSession();
  WorkToolSession? _session;
  @override
  void initState() {
    super.initState();
    if (widget.initialTab >= 0) _selectTab(widget.initialTab);
    if (widget.initialDelivery != null)
      _selectDelivery(widget.initialDelivery!);
  }

  Future<WorkToolSession> _openSession() {
    final opening = _openCurrent();
    opening.then((session) {
      if (!mounted) {
        session.close();
      } else {
        _session = session;
      }
    }, onError: (Object _) {});
    return opening;
  }

  @override
  void didUpdateWidget(covariant WorkspaceWorkbenchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.deliveryRequestId != oldWidget.deliveryRequestId &&
        widget.initialDelivery != null) {
      _selectDelivery(widget.initialDelivery!);
      _revealActiveTab();
    }
    if (oldWidget.initialTab != widget.initialTab && widget.initialTab >= 0) {
      _selectTab(widget.initialTab);
    }
  }

  void _selectTab(int kind, {bool newInstance = false}) {
    final existing = newInstance
        ? null
        : _tabs.where((t) => t.kind == kind).firstOrNull;
    final tab = existing ?? _WorkbenchTab(_nextTabId++, kind);
    if (existing == null) _tabs.add(tab);
    _activeTab = tab.id;
  }

  String _tabLabel(_WorkbenchTab tab) =>
      tab.path?.replaceAll('\\', '/').split('/').last ?? _labels[tab.kind];
  IconData _tabIcon(_WorkbenchTab tab) =>
      tab.path == null ? _icons[tab.kind] : Icons.insert_drive_file_outlined;

  void _revealActiveTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabScroll.hasClients) return;
      final index = _tabs.indexWhere((tab) => tab.id == _activeTab);
      final offset = (index * 164.0).clamp(
        0.0,
        _tabScroll.position.maxScrollExtent,
      );
      _tabScroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  void _selectDelivery(WorkFileChange file) {
    final existing = _tabs
        .where(
          (tab) =>
              tab.delivery?.target == file.target &&
              tab.delivery?.scope == file.scope &&
              tab.path == file.path,
        )
        .firstOrNull;
    final tab =
        existing ??
        _WorkbenchTab(_nextTabId++, 5, path: file.path, delivery: file);
    if (existing == null) _tabs.add(tab);
    _activeTab = tab.id;
  }

  void _openFile(String path) {
    setState(() {
      final existing = _tabs
          .where((tab) => tab.path == path && tab.delivery == null)
          .firstOrNull;
      final tab = existing ?? _WorkbenchTab(_nextTabId++, 5, path: path);
      if (existing == null) _tabs.add(tab);
      _activeTab = tab.id;
    });
    _revealActiveTab();
  }

  void _openTab(int kind, {bool newInstance = false}) {
    setState(() => _selectTab(kind, newInstance: newInstance));
    _revealActiveTab();
  }

  Future<void> _closeTab(_WorkbenchTab tab) async {
    if (!await (_fileControllers[tab.id]?.requestClose() ??
            Future.value(true)) ||
        !mounted)
      return;
    _fileControllers.remove(tab.id);
    _dirtyFiles.remove(tab.id);
    setState(() {
      final index = _tabs.indexOf(tab);
      _tabs.remove(tab);
      if (_activeTab == tab.id) {
        _activeTab = _tabs.isEmpty
            ? null
            : _tabs[(index - 1).clamp(0, _tabs.length - 1)].id;
      }
    });
  }

  Future<bool> _requestCloseAll() async {
    for (final controller in _fileControllers.values.toList()) {
      if (!await controller.requestClose()) return false;
    }
    return true;
  }

  void _dirtyChanged(int id, bool dirty) {
    if (!mounted || _dirtyFiles.contains(id) == dirty) return;
    setState(() {
      if (dirty) {
        _dirtyFiles.add(id);
      } else {
        _dirtyFiles.remove(id);
      }
    });
  }

  Future<WorkToolSession> _openCurrent() {
    final policy =
        ref.read(sessionPolicyProvider)[widget.conversationId] ??
        const SessionPolicy();
    if (policy.sshProfileId.isNotEmpty) {
      return ref
          .read(researchTerminalProvider.notifier)
          .openWorkSession(policy.sshProfileId, policy.remoteRoot);
    }
    return WorkspaceToolSession.open(
      ref.read(desktopWorkspaceHostProvider),
      ref.read(conversationWorkspaceBindingsProvider)[widget.conversationId],
      _token,
    );
  }

  @override
  void dispose() {
    _tabScroll.dispose();
    _token.cancel('工作台已关闭');
    _session?.close();
    super.dispose();
  }

  Future<void> _restore(WorkFileChange change) async {
    if (!change.canRestore) throw StateError('该记录不支持撤销');
    if (ref
            .read(chatControllerProvider)
            .value
            ?.isConversationRunning(widget.conversationId) ??
        false) {
      throw StateError('此会话仍在执行，请停止任务后撤销。');
    }
    final target = jsonDecode(change.target) as Map;
    final WorkToolSession session;
    if (target['kind'] == 'ssh') {
      session = await ref
          .read(researchTerminalProvider.notifier)
          .openWorkSession(
            target['profileId'] as String,
            target['root'] as String,
          );
    } else if (target['kind'] == 'local') {
      session = await WorkspaceToolSession.open(
        ref.read(desktopWorkspaceHostProvider),
        target['workspaceId'] as String,
        _token,
      );
    } else {
      throw StateError('无法定位原工作区');
    }
    try {
      final actual = jsonDecode(session.changeTarget) as Map;
      if (actual['root'] != target['root']) throw StateError('工作区根目录已经改变，未撤销。');
      await session.call('coding_write_file', {
        'scope': change.scope,
        'path': change.path,
        'content': change.before!,
        'expected_sha256': change.afterHash,
      }, _token);
    } finally {
      await session.close();
    }
  }

  Future<void> _authorizeGit(WorkspaceToolSession session, bool write) async {
    if (_token.isCancelled) throw StateError('工作台已关闭');
    final workspace = (await ref.read(desktopWorkspaceHostProvider).list())
        .where((w) => w.id == session.workspace.id)
        .firstOrNull;
    if (workspace == null || workspace.root != session.workspace.root)
      throw StateError('工作区已撤销或改变');
    if (workspace.scopes.isEmpty ||
        workspace.scopes.any(
          (s) =>
              s.access == WorkspaceAccess.deny ||
              (write && s.access != WorkspaceAccess.readWrite),
        )) {
      throw StateError('Git 无法遵循当前目录细分规则；请使用文件工具，或在工作区管理中调整授权。');
    }
  }

  String _path(String value) => value.startsWith(r'\\?\UNC\')
      ? r'\\' + value.substring(8)
      : value.startsWith(r'\\?\')
      ? value.substring(4)
      : value;

  Widget _files() => FutureBuilder<WorkToolSession>(
    future: _opening,
    builder: (context, snapshot) {
      if (snapshot.hasError)
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('工作区暂不可用：${snapshot.error}'),
          ),
        );
      final session = snapshot.data;
      if (session == null)
        return const Center(child: CircularProgressIndicator());
      final descriptor = jsonDecode(session.changeTarget) as Map;
      return GitWorkspacePage(
        workspaceName: session.target,
        rootPath: _path(descriptor['root'] as String),
        embedded: true,
        gitAvailable: session is WorkspaceToolSession,
        onOpenFile: _openFile,
        callFileTool: (name, args) => session.call(name, args, _token),
        authorizeGit: (write) async {
          if (session is! WorkspaceToolSession)
            throw StateError('Git 视图目前仅支持本机');
          await _authorizeGit(session, write);
        },
      );
    },
  );

  Widget _tabBody(_WorkbenchTab tab, bool active) => switch (tab.kind) {
    5 =>
      tab.delivery != null
          ? DeliveredFileTab(
              file: tab.delivery!,
              tabController: _fileControllers.putIfAbsent(
                tab.id,
                FileTabController.new,
              ),
              onDirtyChanged: (dirty) => _dirtyChanged(tab.id, dirty),
            )
          : WorkspaceFileTab(
              path: tab.path!,
              session: _opening,
              tabController: _fileControllers.putIfAbsent(
                tab.id,
                FileTabController.new,
              ),
              onDirtyChanged: (dirty) => _dirtyChanged(tab.id, dirty),
            ),
    6 => WorkAgentsPanel(conversationId: widget.conversationId),
    7 => WorkProcessesPanel(conversationId: widget.conversationId),
    8 => WorkRuntimeLogsPanel(conversationId: widget.conversationId),
    0 => _files(),
    1 => const WorkspaceBrowserPanel(),
    2 => WorkspaceCommandPanel(session: _opening, active: active),
    3 => WorkChangesPage(
      conversationId: widget.conversationId,
      restore: _restore,
      embedded: true,
    ),
    _ => LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .55),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  WorkRoundControls(conversationId: widget.conversationId),
                  WorkApprovalCard(conversationId: widget.conversationId),
                ],
              ),
            ),
          ),
          Expanded(child: WorkTaskPanel(conversationId: widget.conversationId)),
        ],
      ),
    ),
  };

  Widget _startPage(ColorScheme scheme) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.explore_outlined,
              size: 56,
              color: scheme.outlineVariant,
            ),
            const SizedBox(height: 36),
            for (final entry in const [
              (0, '工作区文件', '浏览会话工作区的文件', Icons.folder_copy_outlined),
              (2, '新建终端', '在会话工作区运行命令', Icons.terminal),
              (1, '浏览器', '浏览网页与本地开发服务', Icons.language),
              (6, 'Agents', '查看子代理和递归执行树', Icons.account_tree_outlined),
              (7, 'Services', '查看与控制后台命令和开发服务', Icons.dns_outlined),
              (8, '工作日志', '实时查看执行记录和错误诊断', Icons.receipt_long_outlined),
            ]) ...[
              Material(
                color: scheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _openTab(
                    entry.$1,
                    newInstance: entry.$1 == 1 || entry.$1 == 2,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 22,
                    ),
                    child: Row(
                      children: [
                        Icon(entry.$4, color: scheme.primary, size: 26),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.$2,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                entry.$3,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
            ],
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Column(
      children: [
        Container(
          height: 54,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .6),
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              if (_tabs.isEmpty)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.explore_outlined,
                          size: 19,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        const Text('开始'),
                      ],
                    ),
                  ),
                )
              else ...[
                IconButton(
                  tooltip: '开始页',
                  onPressed: () => setState(() => _activeTab = null),
                  icon: const Icon(Icons.explore_outlined, size: 19),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _tabScroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tab in _tabs)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Material(
                              color: _activeTab == tab.id
                                  ? scheme.surfaceContainerHighest
                                  : scheme.surface,
                              borderRadius: BorderRadius.circular(10),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () =>
                                    setState(() => _activeTab = tab.id),
                                child: SizedBox(
                                  height: 36,
                                  width: 160,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(width: 10),
                                      Icon(_tabIcon(tab), size: 17),
                                      const SizedBox(width: 7),
                                      Expanded(
                                        child: Tooltip(
                                          message: tab.path ?? _tabLabel(tab),
                                          child: Text(
                                            '${_dirtyFiles.contains(tab.id) ? '● ' : ''}${_tabLabel(tab)}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '关闭${_tabLabel(tab)}',
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 30,
                                              height: 30,
                                            ),
                                        padding: EdgeInsets.zero,
                                        iconSize: 16,
                                        onPressed: () => _closeTab(tab),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              IconButton(
                tooltip: '工作日志',
                onPressed: () => _openTab(8),
                icon: const Icon(Icons.receipt_long_outlined, size: 19),
              ),
              PopupMenuButton<int>(
                tooltip: '新建标签',
                icon: const Icon(Icons.add, size: 20),
                onSelected: (kind) =>
                    _openTab(kind, newInstance: kind == 1 || kind == 2),
                itemBuilder: (_) => [
                  for (var i = 0; i < _labels.length; i++)
                    if (i != 5)
                      PopupMenuItem(
                        value: i,
                        child: Row(
                          children: [
                            Icon(_icons[i], size: 18),
                            const SizedBox(width: 12),
                            Text(_labels[i]),
                          ],
                        ),
                      ),
                ],
              ),
              if (widget.onToggleExpanded != null)
                IconButton(
                  tooltip: widget.expanded ? '恢复分栏' : '放大工作台',
                  onPressed: widget.onToggleExpanded,
                  icon: Icon(
                    widget.expanded ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 21,
                  ),
                ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: '收起工作台',
                  onPressed: () async {
                    if (await _requestCloseAll() && mounted)
                      widget.onClose?.call();
                  },
                  icon: const Icon(Icons.chevron_right, size: 20),
                ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Offstage(
                  offstage: _activeTab != null,
                  child: _startPage(scheme),
                ),
              ),
              for (final tab in _tabs)
                Positioned.fill(
                  key: ValueKey(tab.id),
                  child: Offstage(
                    offstage: _activeTab != tab.id,
                    child: ExcludeFocus(
                      excluding: _activeTab != tab.id,
                      child: TickerMode(
                        enabled: _activeTab == tab.id,
                        child: _tabBody(tab, _activeTab == tab.id),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return Material(color: scheme.surface, child: content);
    return PopScope(
      canPop: _allowPop || _dirtyFiles.isEmpty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || !await _requestCloseAll() || !mounted) return;
        setState(() => _allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('工作台')),
        body: content,
      ),
    );
  }
}
