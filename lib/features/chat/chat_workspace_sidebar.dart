import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/desktop_providers.dart';
import '../../data/db/app_database.dart' show Project;
import '../../domain/desktop/workspace_host.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../state/conversation_previews.dart';
import '../../state/session_policy.dart';
import '../../state/work_agents.dart';
import '../../state/work_processes.dart';
import '../../state/work_questions.dart';
import '../../state/work_approvals.dart';
import '../../data/conversation_repository.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import '../library/resources_page.dart';
import '../workspaces/desktop_workspaces_page.dart';
import 'controllers/conversation_sidebar_controller.dart';
import 'jump_to_message.dart';
import 'widgets/conversation_history_list.dart';

final _desktopProjectsProvider = FutureProvider.autoDispose<List<Project>>(
  (ref) => ref.read(projectRepositoryProvider).list(),
);

@immutable
class _HistoryListSlice {
  const _HistoryListSlice({required this.currentId, required this.items});

  final String? currentId;
  final List<_HistoryItemSlice> items;

  @override
  bool operator ==(Object other) {
    if (other is! _HistoryListSlice) return false;
    if (currentId != other.currentId || items.length != other.items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (items[i] != other.items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(currentId, Object.hashAll(items));
}

@immutable
class _HistoryItemSlice {
  const _HistoryItemSlice({
    required this.id,
    required this.title,
    required this.mode,
    this.projectId,
    required this.workMode,
  });

  final String id;
  final String title;
  final ConversationMode mode;
  final String? projectId;
  final bool workMode;

  @override
  bool operator ==(Object other) =>
      other is _HistoryItemSlice &&
      id == other.id &&
      title == other.title &&
      mode == other.mode &&
      projectId == other.projectId &&
      workMode == other.workMode;

  @override
  int get hashCode => Object.hash(id, title, mode, projectId, workMode);
}

/// Shared workspace navigation and conversation history for shell and drawer.
class ChatWorkspaceSidebar extends ConsumerStatefulWidget {
  const ChatWorkspaceSidebar({
    super.key,
    this.onCollapse,
    this.desktopMode = false,
  });

  final VoidCallback? onCollapse;
  final bool desktopMode;

  @override
  ConsumerState<ChatWorkspaceSidebar> createState() =>
      _ChatWorkspaceSidebarState();
}

class _ChatWorkspaceSidebarState extends ConsumerState<ChatWorkspaceSidebar> {
  late final ConversationSidebarController _history;
  int _navigationEpoch = 0;
  String? _renamingId; // id of the conversation being renamed inline
  final _renameCtrl = TextEditingController();
  final _collapsedGroups = <String>{};
  bool _desktopSearchOpen = false;
  bool _workFilter = false, _showArchived = false, _selectingSessions = false;
  String? _filterConversationId;
  final _selectedSessions = <String>{};
  bool _runningView = false;
  final _activitySignatures = <String, int>{};
  final _activityAt = <String, DateTime>{};
  final _activityOrder = <String>[];
  Timer? _activityRefresh;
  late final Listenable _agentEvents, _processEvents;

  // Capture activity as it happens, but reorder at most once per five seconds.
  // Completed tasks remain in this view for the current app session.
  void _captureActivity() {
    final state = ref.read(chatControllerProvider).value;
    if (state == null) return;
    final agents = ref.read(workAgentsProvider).records;
    final processes = ref.read(workProcessesProvider).records;
    final questions = ref.read(workQuestionsProvider);
    final approvals = ref.read(workApprovalsProvider);
    var changed = false;
    for (final c in state.conversations.where((c) => c.workMode)) {
      final checkpoint = state.sessionCheckpoints[c.id];
      final children = agents.where(
        (a) => a.conversationId == c.id && !a.external,
      );
      final commands = processes.where(
        (p) => p.conversationId == c.id && !p.service,
      );
      final waiting =
          questions.any((q) => q.conversationId == c.id) ||
          approvals.any((q) => q.conversationId == c.id);
      final active =
          state.isConversationRunning(c.id) ||
          waiting ||
          checkpoint?.status == SessionExecutionStatus.waiting ||
          children.any((a) => !a.terminal) ||
          commands.any((p) => p.active);
      final last = c.activePath.lastOrNull;
      final signature = Object.hash(
        checkpoint?.updatedAt,
        checkpoint?.status,
        active,
        waiting,
        last?.content.length,
        last?.reasoning.length,
        last?.searchActivities.length,
        Object.hashAll(
          children.map(
            (a) => Object.hash(
              a.id,
              a.status,
              a.rounds,
              a.output.length,
              a.activity,
            ),
          ),
        ),
        Object.hashAll(
          commands.map((p) => Object.hash(p.id, p.status, p.log.length)),
        ),
      );
      final previous = _activitySignatures[c.id];
      _activitySignatures[c.id] = signature;
      if (previous == signature ||
          (!active && !_activityAt.containsKey(c.id))) {
        continue;
      }
      _activityAt[c.id] = DateTime.now();
      changed = true;
    }
    if (changed && _activityRefresh == null) {
      _activityRefresh = Timer(const Duration(seconds: 5), () {
        _activityRefresh = null;
        if (!mounted) return;
        setState(_refreshActivityOrder);
      });
    }
  }

  void _refreshActivityOrder() {
    final currentIds =
        ref
            .read(chatControllerProvider)
            .value
            ?.conversations
            .map((c) => c.id)
            .toSet() ??
        <String>{};
    _activityAt.removeWhere((id, _) => !currentIds.contains(id));
    final previous = {
      for (var i = 0; i < _activityOrder.length; i++) _activityOrder[i]: i,
    };
    _activityOrder
      ..clear()
      ..addAll(_activityAt.keys)
      ..sort((a, b) {
        final recent = _activityAt[b]!.compareTo(_activityAt[a]!);
        return recent != 0
            ? recent
            : (previous[a] ?? 0).compareTo(previous[b] ?? 0);
      });
  }

  Widget _workViewControl() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: SegmentedButton<bool>(
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(value: false, label: Text('全部工作')),
        ButtonSegment(
          value: true,
          label: Text('正在进行'),
          icon: Icon(Icons.work_history_outlined, size: 15),
        ),
      ],
      selected: {_runningView},
      onSelectionChanged: (value) {
        _captureActivity();
        setState(() {
          _runningView = value.first;
          _refreshActivityOrder();
        });
      },
    ),
  );

  void _toggleSession(Conversation c) => setState(() {
    if (!_selectedSessions.add(c.id)) _selectedSessions.remove(c.id);
  });

  Future<void> _archiveSessions(Iterable<String> ids) async {
    final policies = ref.read(sessionPolicyProvider);
    try {
      await ref.read(sessionPolicyProvider.notifier).saveMany({
        for (final id in ids)
          id: (policies[id] ?? const SessionPolicy()).copyWith(
            archived: !_showArchived,
          ),
      });
      if (mounted) {
        setState(() {
          _selectedSessions.clear();
          _selectingSessions = false;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<void> _deleteSelectedSessions() async {
    final ids = List<String>.of(_selectedSessions);
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('删除 ${ids.length} 个会话？'),
        content: const Text('会话及消息将从本机删除，无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    for (final id in ids) {
      await ref.read(chatControllerProvider.notifier).deleteConversation(id);
      if (!mounted) return;
      if (ref
              .read(chatControllerProvider)
              .value
              ?.conversations
              .any((c) => c.id == id) ==
          true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('部分会话删除失败，已保留失败项目。')));
        return;
      }
      _selectedSessions.remove(id);
    }
    if (mounted) setState(() => _selectingSessions = false);
  }

  Widget _sessionControls(List<Conversation> visible) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: Column(
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('会话', key: ValueKey('sidebar-filter-chat')),
              icon: Icon(Icons.chat_bubble_outline, size: 16),
            ),
            ButtonSegment(
              value: true,
              label: Text('工作', key: ValueKey('sidebar-filter-work')),
              icon: Icon(Icons.work_outline, size: 16),
            ),
          ],
          selected: {_workFilter},
          onSelectionChanged: (v) => setState(() {
            _workFilter = v.first;
            _selectedSessions.clear();
          }),
        ),
        if (_workFilter && !_showArchived) _workViewControl(),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() {
                _showArchived = !_showArchived;
                _selectedSessions.clear();
              }),
              child: Text(_showArchived ? '返回未归档' : '已归档'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                _selectingSessions = !_selectingSessions;
                _selectedSessions.clear();
              }),
              child: Text(_selectingSessions ? '取消' : '多选'),
            ),
          ],
        ),
        if (_selectingSessions)
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _selectedSessions.addAll(visible.map((c) => c.id));
                }),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: _selectedSessions.isEmpty
                    ? null
                    : () => _archiveSessions(List.of(_selectedSessions)),
                child: Text(_showArchived ? '恢复' : '归档'),
              ),
              TextButton(
                onPressed: _selectedSessions.isEmpty
                    ? null
                    : _deleteSelectedSessions,
                child: Text('删除 ${_selectedSessions.length}'),
              ),
            ],
          ),
      ],
    ),
  );
  @override
  void initState() {
    super.initState();
    _history = ConversationSidebarController(
      search: (query) =>
          ref.read(conversationRepositoryProvider).searchMessages(query),
    )..addListener(_onHistoryChanged);
    _agentEvents = ref.read(workAgentsProvider)..addListener(_captureActivity);
    _processEvents = ref.read(workProcessesProvider)
      ..addListener(_captureActivity);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureActivity();
    });
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _activityRefresh?.cancel();
    _agentEvents.removeListener(_captureActivity);
    _processEvents.removeListener(_captureActivity);
    _history.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  Future<void> _openConversation(
    Conversation conversation,
    SearchHit hit,
  ) async {
    final epoch = ++_navigationEpoch;
    final controller = ref.read(chatControllerProvider.notifier);
    ref.read(pendingJumpMessageIdProvider.notifier).clear();
    await controller.selectConversation(conversation.id);
    if (!mounted || epoch != _navigationEpoch) return;
    final current = ref.read(chatControllerProvider).value?.current;
    if (current?.id != conversation.id) return;
    openShellTab(ref, ShellTab.chat);
    ref
        .read(pendingJumpMessageIdProvider.notifier)
        .set(
          hit.messageId.isNotEmpty && current!.messagesLoaded
              ? hit.messageId
              : null,
        );
    _closeDrawerIfAny();
  }

  void _startRename(Conversation c) {
    _renameCtrl.text = c.title;
    setState(() => _renamingId = c.id);
  }

  void _commitRename() {
    final id = _renamingId;
    final text = _renameCtrl.text.trim();
    setState(() => _renamingId = null);
    if (id != null && text.isNotEmpty) {
      ref.read(chatControllerProvider.notifier).renameConversation(id, text);
    }
  }

  Future<void> _confirmDelete(Conversation conversation) async {
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: const Text('删除这段对话？'),
        content: Text('“${conversation.title}”及其中的全部消息会从本机删除，且无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref
          .read(chatControllerProvider.notifier)
          .deleteConversation(conversation.id);
    }
  }

  /// Close the drawer if we're in single-pane mode (no-op in two-pane).
  void _closeDrawerIfAny() {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(chatControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    ref.watch(
      chatControllerProvider.select((async) {
        final s = async.value;
        return _HistoryListSlice(
          currentId: s?.currentId,
          items: [
            for (final c in s?.conversations ?? const <Conversation>[])
              _HistoryItemSlice(
                id: c.id,
                title: c.title,
                mode: c.mode,
                projectId: c.projectId,
                workMode: c.workMode,
              ),
          ],
        );
      }),
    );
    ref.listen(chatControllerProvider, (_, _) => _captureActivity());
    ref.listen(workQuestionsProvider, (_, _) => _captureActivity());
    ref.listen(workApprovalsProvider, (_, _) => _captureActivity());
    final state = ref.read(chatControllerProvider).value;
    final selectedTab = ref.watch(shellTabProvider);
    final settings = ref.watch(settingsControllerProvider).value;
    final workspaceTabs = ShellTab.visible(
      researchModeEnabled: settings?.researchModeEnabled ?? false,
      studyModeEnabled: settings?.studyModeEnabled ?? true,
      creationModeEnabled: settings?.creationModeEnabled ?? true,
    ).where((tab) => tab != ShellTab.settings).toList();
    final all = state?.conversations ?? const <Conversation>[];
    if (_filterConversationId != state?.currentId) {
      _filterConversationId = state?.currentId;
      _workFilter = state?.current?.workMode ?? false;
      _selectedSessions.clear();
    }
    final policies = ref.watch(sessionPolicyProvider);
    final visible = [
      for (final c in all)
        if (_history.matches(c) &&
            c.workMode == _workFilter &&
            (policies[c.id]?.archived ?? false) == _showArchived)
          c,
    ];
    if (_workFilter && _runningView && !_showArchived) {
      final positions = {
        for (var i = 0; i < _activityOrder.length; i++) _activityOrder[i]: i,
      };
      visible.removeWhere((c) => !positions.containsKey(c.id));
      visible.sort((a, b) => positions[a.id]!.compareTo(positions[b.id]!));
    }

    if (widget.desktopMode) {
      return _desktopSidebar(all, visible, state?.currentId);
    }

    void openWorkspace(ShellTab tab) {
      ++_navigationEpoch;
      openShellTab(ref, tab);
      _closeDrawerIfAny();
    }

    void newConversation() {
      controller.newConversation(workMode: _workFilter);
      openWorkspace(ShellTab.chat);
    }

    void toggleArchive() => setState(() {
      _showArchived = !_showArchived;
      _selectedSessions.clear();
    });
    void toggleSelection() => setState(() {
      _selectingSessions = !_selectingSessions;
      _selectedSessions.clear();
    });
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset(
                'assets/branding/assistant.png',
                width: 30,
                height: 30,
                errorBuilder: (_, _, _) => Icon(
                  Icons.auto_awesome_outlined,
                  size: 28,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Expert Chat',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '更多功能',
                icon: const Icon(Icons.more_horiz),
                onSelected: (value) {
                  if (value == 'resources') {
                    _closeDrawerIfAny();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ResourcesPage(),
                      ),
                    );
                  } else {
                    openWorkspace(
                      workspaceTabs.firstWhere((tab) => tab.name == value),
                    );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'resources',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.folder_outlined),
                      title: Text('资料库'),
                    ),
                  ),

                  const PopupMenuDivider(),
                  for (final tab in workspaceTabs.where(
                    (tab) => tab != ShellTab.chat,
                  ))
                    PopupMenuItem(
                      value: tab.name,
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          tab.icon,
                          color: selectedTab == tab ? scheme.primary : null,
                        ),
                        title: Text(tab.label),
                      ),
                    ),
                ],
              ),
              if (widget.onCollapse != null)
                IconButton(
                  tooltip: '收起侧边栏',
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.menu_open_rounded),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('conversation-search-field'),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: '搜索会话',
              filled: true,
              fillColor: scheme.surface.withValues(alpha: .7),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: _history.setQuery,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    side: BorderSide.none,
                    selectedBackgroundColor: scheme.primary.withValues(
                      alpha: .1,
                    ),
                    selectedForegroundColor: scheme.primary,
                    backgroundColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('聊天', key: ValueKey('sidebar-filter-chat')),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('工作', key: ValueKey('sidebar-filter-work')),
                    ),
                  ],
                  selected: {_workFilter},
                  onSelectionChanged: (values) => setState(() {
                    _workFilter = values.first;
                    _selectedSessions.clear();
                  }),
                ),
              ),
              const SizedBox(width: 6),
              PopupMenuButton<String>(
                tooltip: '会话管理与筛选',
                icon: Icon(
                  Icons.tune,
                  size: 20,
                  color: _showArchived || _history.mode != null
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'archive':
                      toggleArchive();
                    case 'select':
                      toggleSelection();
                    case 'all':
                      _history.setMode(null);
                    case 'chat':
                      _history.setMode(ConversationMode.chat);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(_showArchived ? '返回未归档' : '查看已归档'),
                  ),
                  PopupMenuItem(
                    value: 'select',
                    child: Text(_selectingSessions ? '退出多选' : '多选会话'),
                  ),
                  const PopupMenuDivider(),
                  CheckedPopupMenuItem(
                    value: 'all',
                    checked: _history.mode == null,
                    child: const Text('全部类型'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'chat',
                    checked: _history.mode == ConversationMode.chat,
                    child: const Text('仅普通对话'),
                  ),
                ],
              ),
            ],
          ),
          if (_workFilter && !_showArchived) _workViewControl(),
          if (_showArchived || _history.mode != null)
            Wrap(
              spacing: 8,
              children: [
                if (_showArchived)
                  InputChip(label: const Text('已归档'), onDeleted: toggleArchive),
                if (_history.mode != null)
                  InputChip(
                    label: const Text('仅普通对话'),
                    onDeleted: () => _history.setMode(null),
                  ),
              ],
            ),
          if (_selectingSessions)
            Wrap(
              spacing: 2,
              alignment: WrapAlignment.spaceBetween,
              children: [
                TextButton(onPressed: toggleSelection, child: const Text('取消')),
                TextButton(
                  onPressed: () => setState(
                    () => _selectedSessions.addAll(visible.map((c) => c.id)),
                  ),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: _selectedSessions.isEmpty
                      ? null
                      : () => _archiveSessions(List.of(_selectedSessions)),
                  child: Text(_showArchived ? '恢复' : '归档'),
                ),
                TextButton(
                  onPressed: _selectedSessions.isEmpty
                      ? null
                      : _deleteSelectedSessions,
                  child: Text('删除 ${_selectedSessions.length}'),
                ),
              ],
            ),
        ],
      ),
    );

    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(child: header),
                  if (_history.searching)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('正在搜索…')),
                    )
                  else if (_history.error != null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_history.error!),
                            TextButton(
                              onPressed: _history.retry,
                              child: const Text('重试搜索'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
                      sliver: ConversationHistoryList(
                        asSliver: true,
                        compactRows: true,
                        mobileStyle: true,
                        previews: ref.watch(conversationPreviewsProvider),
                        selecting: _selectingSessions,
                        selectedIds: _selectedSessions,
                        onToggleSelection: _toggleSession,
                        onStartSelection: (c) => setState(() {
                          _selectingSessions = true;
                          _selectedSessions.add(c.id);
                        }),
                        onArchive: (c) => _archiveSessions([c.id]),
                        archived: _showArchived,
                        visible: visible,
                        currentId: state?.currentId,
                        query: _history.query,
                        searchHits: _history.hits,
                        renamingId: _renamingId,
                        renameController: _renameCtrl,
                        onCommitRename: _commitRename,
                        onRename: _startRename,
                        onDelete: _confirmDelete,
                        onOpen: _openConversation,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('sidebar-new-chat'),
                      onPressed: newConversation,
                      icon: const Icon(Icons.edit_square, size: 20),
                      label: Text(_workFilter ? '新工作' : '新对话'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '设置',
                    onPressed: () => openWorkspace(ShellTab.settings),
                    icon: const Icon(Icons.settings_outlined, size: 23),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manageWorkspaces() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DesktopWorkspacesPage()),
    );
    if (!mounted) return;
    ref.invalidate(registeredDesktopWorkspacesProvider);
    ref.invalidate(desktopWorkspacesProvider);
  }

  Future<void> _newProjectChat({String? workspaceId, String? projectId}) async {
    setState(() => _showArchived = false);
    final epoch = ++_navigationEpoch;
    final controller = ref.read(chatControllerProvider.notifier);
    controller.newConversation(
      projectId: projectId,
      workMode: workspaceId != null || (projectId == null && _workFilter),
      forceNew: true,
    );
    final conversationId = ref.read(chatControllerProvider).value?.currentId;
    if (conversationId != null &&
        ref.read(desktopWorkspaceHostProvider).supported) {
      try {
        await ref
            .read(conversationWorkspaceBindingsProvider.notifier)
            .select(conversationId, workspaceId);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('项目选择未保存：$error')));
        }
        return;
      }
      if (!mounted ||
          epoch != _navigationEpoch ||
          ref.read(chatControllerProvider).value?.currentId != conversationId) {
        return;
      }
    }
    if (mounted) openShellTab(ref, ShellTab.chat);
  }

  Widget _desktopSidebar(
    List<Conversation> all,
    List<Conversation> visible,
    String? currentId,
  ) {
    final colors = Theme.of(context).colorScheme;
    final supported = ref.watch(desktopWorkspaceHostProvider).supported;
    final bindings = supported
        ? ref.watch(conversationWorkspaceBindingsProvider)
        : const <String, String>{};
    final spaces = ref.watch(registeredDesktopWorkspacesProvider);
    final projects = ref.watch(_desktopProjectsProvider).value ?? <Project>[];
    final assigned = <String>{};
    final slivers = <Widget>[];
    Widget rows(List<Conversation> items) => SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      sliver: ConversationHistoryList(
        asSliver: true,
        compactRows: true,
        previews: ref.watch(conversationPreviewsProvider),
        selecting: _selectingSessions,
        selectedIds: _selectedSessions,
        onToggleSelection: _toggleSession,
        onArchive: (c) => _archiveSessions([c.id]),
        archived: _showArchived,
        visible: items,
        currentId: currentId,
        query: _history.query,
        searchHits: _history.hits,
        renamingId: _renamingId,
        renameController: _renameCtrl,
        onCommitRename: _commitRename,
        onRename: _startRename,
        onDelete: _confirmDelete,
        onOpen: _openConversation,
      ),
    );
    void group(
      String key,
      String name,
      List<Conversation> items,
      VoidCallback onNew, {
      bool documents = false,
    }) {
      assigned.addAll(items.map((c) => c.id));
      final closed = _collapsedGroups.contains(key);
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListTile(
              key: ValueKey('desktop-project-$key'),
              dense: true,
              minTileHeight: 44,
              leading: Icon(
                closed ? Icons.folder_outlined : Icons.folder_open_outlined,
                size: 20,
              ),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: documents
                  ? const Text('资料项目', style: TextStyle(fontSize: 11))
                  : null,
              onTap: () => setState(() {
                if (closed) {
                  _collapsedGroups.remove(key);
                } else {
                  _collapsedGroups.add(key);
                }
              }),
              trailing: IconButton(
                tooltip: '在项目中新建会话',
                onPressed: onNew,
                icon: const Icon(Icons.add, size: 18),
              ),
            ),
          ),
        ),
      );
      if (!closed && items.isNotEmpty) {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.only(left: 18),
            sliver: rows(items),
          ),
        );
      }
    }

    if (_history.query.isEmpty &&
        !_showArchived &&
        !(_workFilter && _runningView)) {
      if (_workFilter) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '工作',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (supported)
                    IconButton(
                      tooltip: '管理项目工作区',
                      onPressed: _manageWorkspaces,
                      icon: const Icon(Icons.add, size: 18),
                    ),
                ],
              ),
            ),
          ),
        );
        for (final space in spaces.value ?? <DesktopWorkspace>[]) {
          if (space.id == defaultDesktopWorkspaceId) continue;
          group(
            'workspace-${space.id}',
            space.name,
            visible
                .where((c) => c.workMode && bindings[c.id] == space.id)
                .toList(),
            () => _newProjectChat(workspaceId: space.id),
          );
        }
        if (spaces.hasError) {
          slivers.add(
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                child: Text(
                  '工作区暂未载入，可在管理页面检查。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          );
        }
        if ((spaces.value ?? [])
                .where((w) => w.id != defaultDesktopWorkspaceId)
                .isEmpty &&
            projects.isEmpty) {
          slivers.add(
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 6, 20, 12),
                child: Text(
                  '添加项目，将相关会话放在一起。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          );
        }
      }
      if (!_workFilter) {
        for (final project in projects) {
          group(
            'document-${project.id}',
            project.name,
            visible
                .where(
                  (c) =>
                      !c.workMode &&
                      c.projectId == project.id &&
                      !assigned.contains(c.id),
                )
                .toList(),
            () => _newProjectChat(projectId: project.id),
            documents: true,
          );
        }
      }
    }
    final recent = _history.query.isEmpty
        ? visible.where((c) => !assigned.contains(c.id)).toList()
        : visible;
    if (_history.searching) {
      slivers.add(
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(24), child: Text('正在搜索…')),
        ),
      );
    } else if (_history.error != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: TextButton(
            onPressed: _history.retry,
            child: Text('${_history.error} 点击重试'),
          ),
        ),
      );
    } else if (_history.query.isNotEmpty) {
      for (final work in [_workFilter]) {
        slivers.add(
          SliverToBoxAdapter(
            child: _SidebarSectionLabel(work ? '工作会话' : '聊天会话'),
          ),
        );
        slivers.add(rows(recent.where((c) => c.workMode == work).toList()));
      }
    } else if (recent.isNotEmpty) {
      slivers.add(rows(recent));
    } else {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 16, 16),
            child: Text(
              _workFilter && _runningView ? '暂无正在进行的工作' : '从一段新对话开始',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ),
      );
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 24)));
    return Material(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 8, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Expert Chat',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.6,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '收起侧边栏',
                    onPressed: widget.onCollapse,
                    icon: const Icon(Icons.view_sidebar_outlined, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 10, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      key: const ValueKey('sidebar-new-chat'),
                      onPressed: () => _newProjectChat(),
                      icon: const Icon(Icons.edit_square, size: 19),
                      label: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(_workFilter ? '新工作' : '新对话'),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onSurface,
                        minimumSize: const Size(0, 44),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '搜索会话',
                    onPressed: () => setState(() {
                      _desktopSearchOpen = !_desktopSearchOpen;
                      if (!_desktopSearchOpen) _history.setQuery('');
                    }),
                    icon: const Icon(Icons.search, size: 21),
                  ),
                ],
              ),
            ),
            _sessionControls(visible),
            if (_desktopSearchOpen)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: TextField(
                  key: const ValueKey('conversation-search-field'),
                  autofocus: true,
                  onChanged: _history.setQuery,
                  decoration: InputDecoration(
                    hintText: '搜索会话',
                    isDense: true,
                    filled: true,
                    fillColor: colors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: CustomScrollView(
                key: const ValueKey('desktop-project-conversations'),
                slivers: slivers,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: [
                  TextButton.icon(
                    key: const ValueKey('sidebar-resources'),
                    onPressed: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ResourcesPage(),
                        ),
                      );
                      if (mounted) ref.invalidate(_desktopProjectsProvider);
                    },
                    icon: const Icon(Icons.folder_copy_outlined, size: 17),
                    label: const Text('资料库'),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
      ),
    ),
  );
}

class _WorkspaceDestination extends StatelessWidget {
  const _WorkspaceDestination({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final ShellTab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        dense: true,
        minTileHeight: 40,
        selected: selected,
        leading: Icon(
          selected ? tab.selectedIcon : tab.icon,
          size: 20,
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: Text(
          tab.label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        trailing: selected
            ? Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              )
            : null,
        onTap: onTap,
      ),
    );
  }
}
