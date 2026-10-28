import '../../core/runtime_listenable.dart';
import '../../domain/host/host_client.dart';
import '../../core/application_surface.dart';
import 'files/work_file_access.dart';
import '../../core/prototype_widgets.dart';
import '../../domain/workbench/changes/restore_work_file_change.dart';
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
import '../chat/widgets/work_approval_card.dart';
import '../../state/work_changes.dart';
import '../../data/models.dart' show MessageRole;
import '../../state/work_processes.dart';
import '../../state/work_agents.dart';
import '../chat/widgets/chat_workspace_options.dart';
import '../chat/widgets/composer_model_picker.dart';
import '../settings/settings_page.dart';
import '../shell/conversation_return_scope.dart';
import '../research/research_terminal_page.dart';

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
  int _section = 0;
  static int _sectionFor(int kind) => switch (kind) {
    0 || 3 || 5 || 9 => 0,
    6 || 10 => 2,
    _ => 1,
  };
  bool _allowPop = false;
  static const _labels = [
    '工作区文件',
    '浏览器',
    '终端',
    '改动',
    '任务',
    '',
    '子代理',
    '后台进程',
    '日志',
    'Git',
    '主代理设置',
  ];
  final _token = CancelToken();
  late final Future<WorkToolSession> _opening = _openSession();
  WorkToolSession? _session;
  bool get _hasLocalWorkspace =>
      ref.read(desktopWorkspaceHostProvider).supported;
  bool get _canBrowseFiles =>
      _hasLocalWorkspace ||
      (ref
              .read(sessionPolicyProvider)[widget.conversationId]
              ?.sshProfileId
              .isNotEmpty ??
          false);
  @override
  void initState() {
    super.initState();
    _selectTab(widget.initialTab >= 0 ? widget.initialTab : 3);
    if (widget.initialDelivery != null) {
      _selectDelivery(widget.initialDelivery!);
    }
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
    if (kind < 0 || kind >= _labels.length) kind = 6;
    final existing = newInstance
        ? null
        : _tabs.where((t) => t.kind == kind).firstOrNull;
    final tab = existing ?? _WorkbenchTab(_nextTabId++, kind);
    if (existing == null) _tabs.add(tab);
    _activeTab = tab.id;
    _section = _sectionFor(tab.kind);
  }

  bool _isInstance(_WorkbenchTab tab) =>
      tab.kind == 5 || tab.kind == 1 || tab.kind == 2;
  int get _activeKind =>
      _tabs.where((t) => t.id == _activeTab).firstOrNull?.kind ??
      const [3, 4, 6][_section];

  String _tabLabel(_WorkbenchTab tab) =>
      tab.path?.replaceAll('\\', '/').split('/').last ?? _labels[tab.kind];

  void _revealActiveTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabScroll.hasClients) return;
      final index = _tabs
          .where((t) => _sectionFor(t.kind) == _section)
          .toList()
          .indexWhere((tab) => tab.id == _activeTab);
      final offset = (index * 164.0).clamp(
        0.0,
        _tabScroll.position.maxScrollExtent,
      );
      if (MediaQuery.disableAnimationsOf(context)) {
        _tabScroll.jumpTo(offset);
        return;
      }
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
    _section = _sectionFor(tab.kind);
  }

  void _openFile(String path) {
    setState(() {
      final existing = _tabs
          .where((tab) => tab.path == path && tab.delivery == null)
          .firstOrNull;
      final tab = existing ?? _WorkbenchTab(_nextTabId++, 5, path: path);
      if (existing == null) _tabs.add(tab);
      _activeTab = tab.id;
      _section = _sectionFor(tab.kind);
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
        !mounted) {
      return;
    }
    _fileControllers.remove(tab.id);
    _dirtyFiles.remove(tab.id);
    setState(() {
      _tabs.remove(tab);
      if (_activeTab == tab.id) {
        _activeTab = _tabs
            .where((t) => _sectionFor(t.kind) == _section)
            .lastOrNull
            ?.id;
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
    if (HostClient.current case final client?) {
      await client.call('runtime', 'changes.restore', {
        'id': change.id,
        'afterHash': change.afterHash,
        'change': change.toJson(),
        'recreate': change.recreateNewFile,
      });
      return;
    }
    if (!change.canRestore && !change.recreateNewFile) {
      throw StateError('该记录不支持撤销');
    }
    if (ref
            .read(chatControllerProvider)
            .value
            ?.isConversationRunning(widget.conversationId) ??
        false) {
      throw StateError('此会话仍在执行，请停止任务后撤销。');
    }
    final session = await openDeliverySession(ref, change, _token);
    try {
      await restoreReviewedFileChange(session, change, _token);
    } finally {
      await session.close();
    }
  }

  Future<void> _authorizeGit(WorkspaceToolSession session, bool write) async {
    if (_token.isCancelled) throw StateError('工作台已关闭');
    final workspace = (await ref.read(desktopWorkspaceHostProvider).list())
        .where((w) => w.id == session.workspace.id)
        .firstOrNull;
    if (workspace == null || workspace.root != session.workspace.root) {
      throw StateError('工作区已撤销或改变');
    }
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

  Widget _files({bool git = false}) => !_canBrowseFiles
      ? const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('当前是手机本地任务。需要浏览电脑文件时，请先连接 SSH 或远程电脑。'),
          ),
        )
      : FutureBuilder<WorkToolSession>(
          future: _opening,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('工作区暂不可用：${snapshot.error}'),
                ),
              );
            }
            final session = snapshot.data;
            if (session == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final descriptor = jsonDecode(session.changeTarget) as Map;
            return GitWorkspacePage(
              initialView: git ? 1 : 0,
              compactHeader: true,
              workspaceName: session.target,
              rootPath: _path(descriptor['root'] as String),
              embedded: true,
              gitAvailable: session is WorkspaceToolSession,
              onOpenFile: _openFile,
              callFileTool: (name, args) => session.call(name, args, _token),
              authorizeGit: (write) async {
                if (session is! WorkspaceToolSession) {
                  throw StateError('Git 视图目前仅支持本机');
                }
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
    6 => WorkAgentsPanel(
      conversationId: widget.conversationId,
      showConfiguration: false,
    ),
    7 => WorkProcessesPanel(conversationId: widget.conversationId),
    8 => WorkRuntimeLogsPanel(conversationId: widget.conversationId),
    0 => _files(),
    9 => _files(git: true),
    10 => ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('主代理模型'),
        ComposerModelPicker(
          conversationId: widget.conversationId,
          enabled: true,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: PrototypeButton(
            key: const ValueKey('workbench-edit-main-instructions'),
            label: '编辑主代理指令',
            icon: Icons.edit_note_outlined,
            small: true,
            variant: PrototypeButtonVariant.ghost,
            onPressed: () => Navigator.of(context).push(
              applicationSurfaceRoute<void>(
                context,
                (_) => const SettingsPage(
                  initialCategory: SettingsCategory.assistants,
                ),
                protectRoot: false,
                settings: const RouteSettings(
                  name: conversationSettingsRouteName,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
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
                  if (!widget.embedded || widget.expanded)
                    WorkApprovalCard(conversationId: widget.conversationId),
                ],
              ),
            ),
          ),
          Expanded(
            child: WorkTaskPanel(
              conversationId: widget.conversationId,
              onOpenFile: _selectDelivery,
            ),
          ),
        ],
      ),
    ),
  };

  Widget _emptySection() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(switch (_section) {
          0 => '这个会话还没有打开的文件。',
          1 => '选择任务、终端或浏览器查看运行情况。',
          _ => '查看主代理配置与子代理。',
        }),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () => _openTab(switch (_section) {
            0 => 0,
            1 => 4,
            _ => 6,
          }),
          child: const Text('打开'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final changes = ref
        .watch(workChangesProvider)
        .where((r) => r.conversationId == widget.conversationId)
        .map((r) => (r.target, r.scope, r.path))
        .toSet()
        .length;
    final processes = ref.watch(workProcessesProvider);
    final agents = ref.watch(workAgentsProvider);
    final conversation = ref
        .watch(chatControllerProvider)
        .value
        ?.conversations
        .where((c) => c.id == widget.conversationId)
        .firstOrNull;
    final assistant = conversation?.activePath
        .where((m) => m.role == MessageRole.assistant)
        .lastOrNull;
    final deliveries = assistant == null
        ? <WorkFileChange>[]
        : finalDeliveryFiles(
            ref.watch(workChangesProvider),
            widget.conversationId,
            assistant.id,
          );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('html-workbench-header'),
          height: 50,
          child: Row(
            children: [
              const SizedBox(width: 16),
              const Text(
                '任务工作区',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              if (!widget.embedded)
                Expanded(
                  child: ChatWorkspaceBar(
                    conversationId: widget.conversationId,
                    busy: false,
                    plain: true,
                  ),
                ),
              if (widget.embedded) const Spacer(),
              PopupMenuButton<int>(
                tooltip: '更多工作工具',
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: _openTab,
                itemBuilder: (_) => [
                  for (final kind in [
                    if (_canBrowseFiles) 2,
                    1,
                    if (_hasLocalWorkspace) 9,
                    7,
                    8,
                    10,
                  ])
                    PopupMenuItem(value: kind, child: Text(_labels[kind])),
                ],
              ),
              if (widget.onToggleExpanded != null)
                PrototypeIconButton(
                  tooltip: widget.expanded ? '恢复分栏' : '放大工作台',
                  onPressed: widget.onToggleExpanded,
                  icon: widget.expanded
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                ),
              PrototypeIconButton(
                tooltip: '收起工作台',
                onPressed: () async {
                  if (await _requestCloseAll() && context.mounted) {
                    if (widget.onClose != null) {
                      widget.onClose!();
                    } else {
                      Navigator.of(context).pop();
                    }
                  }
                },
                icon: Icons.chevron_right,
              ),
            ],
          ),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([
            runtimeListenable(processes),
            runtimeListenable(agents),
          ]),
          builder: (context, _) {
            final counts = [
              changes,
              deliveries.length,
              agents.records
                  .where(
                    (r) =>
                        r.conversationId == widget.conversationId &&
                        !r.external,
                  )
                  .length,
            ];
            return PrototypeTabStrip<int>(
              tabs: [
                for (var i = 0; i < 3; i++)
                  PrototypeTab(
                    key: ValueKey('workbench-section-$i'),
                    value: i,
                    label: const ['文件', '成果', '代理'][i],
                    count: counts[i],
                  ),
              ],
              value: _section,
              onChanged: (i) => setState(() {
                _section = i;
                final existing = _tabs
                    .where((t) => _sectionFor(t.kind) == i)
                    .lastOrNull;
                if (existing != null) {
                  _activeTab = existing.id;
                } else {
                  _selectTab(const [3, 4, 6][i]);
                }
              }),
            );
          },
        ),
        if (_section == 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: PrototypeSegmentedControl<int>(
                      segments: [
                        for (final kind in switch (_section) {
                          0 => [
                            3,
                            if (_canBrowseFiles) 0,
                            if (_hasLocalWorkspace) 9,
                          ],
                          1 => [4, 2, 1, 7, 8],
                          _ => [10, 6],
                        })
                          PrototypeSegment(
                            value: kind,
                            label: kind == 3
                                ? '本轮改动'
                                : kind == 0
                                ? '全部文件'
                                : _labels[kind],
                          ),
                      ],
                      value: _activeKind == 5 ? 0 : _activeKind,
                      onChanged: _openTab,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if ((_section == 1 && _activeKind != 4) ||
            (_section == 2 && _activeKind == 10))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => _openTab(_section == 1 ? 4 : 6),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: Text(_section == 1 ? '返回成果' : '返回代理'),
                ),
                const SizedBox(width: 8),
                Text(
                  _labels[_activeKind],
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        if (_section == 1 &&
            (ref
                    .watch(sessionPolicyProvider)[widget.conversationId]
                    ?.sshProfileId
                    .isNotEmpty ??
                false))
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 6),
              child: PrototypeButton(
                label: '在科研终端中打开',
                small: true,
                variant: PrototypeButtonVariant.ghost,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ResearchTerminalPage(),
                  ),
                ),
              ),
            ),
          ),
        if ((_activeKind == 5 ||
                _activeKind == 0 ||
                _activeKind == 1 ||
                _activeKind == 2) &&
            _tabs.any(
              (t) =>
                  _sectionFor(t.kind) == _section &&
                  _isInstance(t) &&
                  (_activeKind == 0 || _activeKind == 5
                      ? t.kind == 5
                      : t.kind == _activeKind),
            ))
          SizedBox(
            key: const ValueKey('workbench-instance-strip'),
            height: MediaQuery.sizeOf(context).width < 840 ? 44 : 40,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: _tabScroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final tab in _tabs.where(
                          (t) =>
                              _sectionFor(t.kind) == _section &&
                              _isInstance(t) &&
                              (_activeKind == 0 || _activeKind == 5
                                  ? t.kind == 5
                                  : t.kind == _activeKind),
                        ))
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _InstanceTab(
                              label:
                                  '${_dirtyFiles.contains(tab.id) ? '● ' : ''}${_tabLabel(tab)}',
                              selected: _activeTab == tab.id,
                              onTap: () => setState(() => _activeTab = tab.id),
                              onClose: () => _closeTab(tab),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_activeKind == 1 || _activeKind == 2)
                  PrototypeIconButton(
                    icon: Icons.add,
                    tooltip: _activeKind == 2 ? '新建终端' : '新建浏览器',
                    onPressed: () => _openTab(_activeKind, newInstance: true),
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
                  child: _emptySection(),
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
      child: Scaffold(body: content),
    );
  }
}

class _InstanceTab extends StatelessWidget {
  const _InstanceTab({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap, onClose;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: selected ? c.panel : c.surface,
        border: Border(
          bottom: BorderSide(
            color: selected ? c.ink : c.line,
            width: selected ? 2 : 1,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Tooltip(
                  message: label,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.ink),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: MediaQuery.sizeOf(context).width < 840 ? 44 : 28,
            height: MediaQuery.sizeOf(context).width < 840 ? 44 : 30,
            child: IconButton(
              tooltip: '关闭$label',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              iconSize: 14,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}
