import '../../core/runtime_listenable.dart';
import 'package:expert_chat/core/app_toast.dart';
import '../../core/line_icon.dart';
import '../../core/application_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/prototype_widgets.dart';
import '../../core/desktop_providers.dart';
import '../../data/db/app_database.dart' show Project;
import '../../domain/desktop/workspace_host.dart';
import '../../domain/desktop/workspace_identity.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../state/conversation_previews.dart';
import '../../state/session_policy.dart';
import '../../state/work_processes.dart';
import '../../state/work_agents.dart';
import '../../state/conversation_activity.dart';
import '../../state/research_terminal_controller.dart';
import '../shell/automation_status.dart';
import '../../state/work_questions.dart';
import '../../state/work_approvals.dart';
import '../../data/conversation_repository.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import '../workspaces/desktop_workspaces_page.dart';
import 'controllers/conversation_sidebar_controller.dart';
import 'jump_to_message.dart';
import 'widgets/conversation_history_list.dart';
import 'widgets/sidebar_reorder_motion.dart';

final _desktopProjectsProvider = FutureProvider.autoDispose<List<Project>>(
  (ref) => ref.watch(projectRepositoryProvider).list(),
);

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
  late final Listenable _activityEvents;
  int _navigationEpoch = 0;
  String? _renamingId; // id of the conversation being renamed inline
  final _renameCtrl = TextEditingController();
  bool _desktopSearchOpen = false,
      _showArchived = false,
      _selectingSessions = false;
  final _selectedSessions = <String>{};
  bool _runningView = false;
  final _workActivitySeen = <String>{};

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
        AppToastMessenger.of(
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
        AppToastMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('部分会话删除失败，已保留失败项目。')));
        return;
      }
      _selectedSessions.remove(id);
    }
    if (mounted) setState(() => _selectingSessions = false);
  }

  Widget _historyMenu() => PopupMenuButton<String>(
    tooltip: '会话管理与筛选',
    icon: const Icon(Icons.filter_list, size: 16),
    padding: EdgeInsets.zero,
    style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(
        Size(widget.desktopMode ? 28 : 44, widget.desktopMode ? 28 : 44),
      ),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    ),
    onSelected: (value) {
      if (value == 'archive') {
        setState(() {
          _showArchived = !_showArchived;
          _selectedSessions.clear();
        });
      } else if (value == 'select') {
        setState(() {
          _selectingSessions = !_selectingSessions;
          _selectedSessions.clear();
        });
      } else {
        _history.setMode(
          value == 'all' ? null : ConversationMode.values.byName(value),
        );
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'archive',
        child: Text(_showArchived ? '返回未归档' : '已归档'),
      ),
      PopupMenuItem(
        value: 'select',
        child: Text(_selectingSessions ? '取消多选' : '多选'),
      ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem(
        value: 'all',
        checked: _history.mode == null,
        child: const Text('全部类型'),
      ),
      for (final entry in [
        (ConversationMode.chat, '仅普通对话'),
        (ConversationMode.story, '仅故事'),
        (ConversationMode.ensemble, '仅角色大乱斗'),
        (ConversationMode.study, '仅学习'),
      ])
        CheckedPopupMenuItem(
          value: entry.$1.name,
          checked: _history.mode == entry.$1,
          child: Text(entry.$2),
        ),
    ],
  );
  Widget _sessionControls(List<Conversation> visible) => !_selectingSessions
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              PrototypeButton(
                label: '取消',
                small: true,
                onPressed: () => setState(() {
                  _selectingSessions = false;
                  _selectedSessions.clear();
                }),
              ),
              PrototypeButton(
                label: '全选',
                small: true,
                onPressed: () => setState(
                  () => _selectedSessions.addAll(visible.map((c) => c.id)),
                ),
              ),
              PrototypeButton(
                label: _showArchived ? '恢复' : '归档',
                small: true,
                onPressed: _selectedSessions.isEmpty
                    ? null
                    : () => _archiveSessions(List.of(_selectedSessions)),
              ),
              PrototypeButton(
                label: '删除 ${_selectedSessions.length}',
                small: true,
                variant: PrototypeButtonVariant.danger,
                onPressed: _selectedSessions.isEmpty
                    ? null
                    : _deleteSelectedSessions,
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
    _activityEvents = Listenable.merge([
      runtimeListenable(ref.read(workAgentsProvider)),
      runtimeListenable(ref.read(workProcessesProvider)),
    ]);
    _activityEvents.addListener(_onHistoryChanged);
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _activityEvents.removeListener(_onHistoryChanged);
    _history.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  Future<void> _openConversation(
    Conversation conversation,
    SearchHit hit,
  ) async {
    final epoch = ++_navigationEpoch;
    final initialTab = ref.read(shellTabProvider);
    final controller = ref.read(chatControllerProvider.notifier);
    ref.read(pendingJumpMessageIdProvider.notifier).clear();
    await controller.selectConversation(conversation.id);
    if (!mounted ||
        epoch != _navigationEpoch ||
        ref.read(shellTabProvider) != initialTab) {
      return;
    }
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

  bool _hovering = false;
  List<String> _frozenOrder = [];
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatControllerProvider).value;
    final settings = ref.watch(settingsControllerProvider).value;
    final policies = ref.watch(sessionPolicyProvider);
    final approvals = ref.watch(workApprovalsProvider);
    final questions = ref.watch(workQuestionsProvider);
    final all = state?.conversations ?? <Conversation>[];
    final visible = all
        .where(
          (c) =>
              _history.matches(c) &&
              (policies[c.id]?.archived ?? false) == _showArchived,
        )
        .toList();
    DateTime activity(Conversation c) {
      final checkpoint = state?.sessionCheckpoints[c.id]?.updatedAt;
      return checkpoint != null && checkpoint.isAfter(c.updatedAt)
          ? checkpoint
          : c.updatedAt;
    }

    visible.sort((a, b) => activity(b).compareTo(activity(a)));
    if (_hovering) {
      final position = {
        for (var i = 0; i < _frozenOrder.length; i++) _frozenOrder[i]: i,
      };
      visible.sort(
        (a, b) =>
            (position[a.id] ?? 100000).compareTo(position[b.id] ?? 100000),
      );
    }
    final bindings = ref.watch(conversationWorkspaceBindingsProvider);
    final spaces =
        ref.watch(registeredDesktopWorkspacesProvider).value ??
        <DesktopWorkspace>[];
    final projects = ref.watch(_desktopProjectsProvider).value ?? <Project>[];
    final collapsed = settings?.ui.sidebarCollapsedGroups.toSet() ?? <String>{};
    void destination(ShellTab tab) {
      openShellTab(ref, tab);
      _closeDrawerIfAny();
    }

    Widget rows(List<Conversation> items) => items.isEmpty
        ? Padding(
            padding: const EdgeInsets.fromLTRB(26, 2, 8, 4),
            child: Text(
              '还没有对话',
              style: TextStyle(
                fontSize: 12,
                color: PrototypeColors.of(context).muted,
              ),
            ),
          )
        : ConversationHistoryList(
            compactRows: true,
            prototypeRows: true,
            mobileStyle: !widget.desktopMode,
            shrinkWrap: true,
            currentSessionActive: ref.watch(shellTabProvider) == ShellTab.chat,
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
            visible: items,
            currentId: state?.currentId,
            query: _history.query,
            searchHits: _history.hits,
            renamingId: _renamingId,
            renameController: _renameCtrl,
            onCommitRename: _commitRename,
            onRename: _startRename,
            onDelete: _confirmDelete,
            onOpen: _openConversation,
          );
    final proto = PrototypeColors.of(context);
    final rowHeight = widget.desktopMode ? 32.0 : 44.0;
    Widget group(
      String key,
      String label,
      List<Conversation> items, {
      VoidCallback? onNew,
      String? type,
    }) => Column(
      key: ValueKey('sidebar-group-$key'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarReorderMotion(
          key: ValueKey('sidebar-group-title-$key'),
          child: SizedBox(
            height: rowHeight,
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: type == null ? label : '$label · $type',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: settings == null
                          ? null
                          : () async {
                              final next = {...collapsed};
                              if (!next.add(key)) next.remove(key);
                              await ref
                                  .read(settingsControllerProvider.notifier)
                                  .setUiPrefs(
                                    settings.ui.copyWith(
                                      sidebarCollapsedGroups: next.toList(),
                                    ),
                                  );
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            Icon(
                              collapsed.contains(key)
                                  ? Icons.chevron_right
                                  : Icons.expand_more,
                              size: 12,
                              color: proto.muted,
                            ),
                            const SizedBox(width: 6),
                            if (type != null) ...[
                              Icon(
                                type.startsWith('SSH')
                                    ? Icons.cloud_outlined
                                    : Icons.folder_outlined,
                                size: 15,
                                color: proto.muted,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Expanded(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: proto.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (onNew != null)
                  PrototypeIconButton(
                    icon: Icons.add,
                    onPressed: onNew,
                    tooltip: '在此分组新建',
                  ),
              ],
            ),
          ),
        ),
        if (!collapsed.contains(key)) ...[
          const SizedBox(height: 4),
          rows(items),
        ],
      ],
    );
    final active = ref.watch(conversationActiveIdsProvider);
    // Preserve results of tasks seen running in this sidebar instance.
    _workActivitySeen.addAll(active);
    final profiles = ref.watch(researchTerminalProvider).profiles;
    final remoteCounts = ref.watch(remoteAutomationCountsProvider);
    final work = visible
        .where(
          (c) =>
              c.workMode && (!_runningView || _workActivitySeen.contains(c.id)),
        )
        .toList();
    final chats = visible
        .where((c) => !c.workMode && !c.isStoryLike && !c.isStudy)
        .toList();
    final content = <Widget>[];
    content.add(
      Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '工作',
                  key: const ValueKey('sidebar-work-section-label'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: PrototypeColors.of(context).faint,
                  ),
                ),
              ),
            ),
            PrototypeIconButton(
              key: const ValueKey('sidebar-manage-locations'),
              icon: Icons.folder_outlined,
              onPressed: _manageWorkspaces,
              tooltip: '管理执行位置',
            ),
            PopupMenuButton<bool>(
              key: const ValueKey('sidebar-work-filter'),
              tooltip: '工作筛选',
              icon: const LineIcon(Icons.more_vert, size: 16),
              padding: EdgeInsets.zero,
              style: ButtonStyle(
                minimumSize: WidgetStatePropertyAll(
                  Size(
                    widget.desktopMode ? 28 : 44,
                    widget.desktopMode ? 28 : 44,
                  ),
                ),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              ),
              onSelected: (v) => setState(() => _runningView = v),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: false,
                  checked: !_runningView,
                  child: const Text('全部工作'),
                ),
                CheckedPopupMenuItem(
                  value: true,
                  checked: _runningView,
                  child: const Text('只看进行中'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final workGroups = <String, List<Conversation>>{};
    final canonical = <String, String>{}, aliases = <String, String>{};
    for (final space in spaces) {
      aliases[space.id] = canonical.putIfAbsent(
        workspaceNavigationIdentity(space),
        () => space.id,
      );
    }
    for (final c in work) {
      final ssh = policies[c.id]?.sshProfileId ?? '';
      final key = ssh.isNotEmpty
          ? 'ssh:$ssh'
          : aliases[bindings[c.id]] ??
                bindings[c.id] ??
                defaultDesktopWorkspaceId;
      (workGroups[key] ??= []).add(c);
    }
    if (workGroups.isEmpty) workGroups[defaultDesktopWorkspaceId] = [];
    final orderedGroups = workGroups.entries.toList()
      ..sort((a, b) {
        final currentA = a.value.any((c) => c.id == state?.currentId);
        final currentB = b.value.any((c) => c.id == state?.currentId);
        if (currentA != currentB) return currentA ? -1 : 1;
        if (a.value.isEmpty || b.value.isEmpty) {
          return a.value.length.compareTo(b.value.length);
        }
        return visible
            .indexOf(a.value.first)
            .compareTo(visible.indexOf(b.value.first));
      });
    for (final entry in orderedGroups) {
      final ssh = entry.key.startsWith('ssh:');
      final profile = ssh
          ? profiles.where((p) => p.id == entry.key.substring(4)).firstOrNull
          : null;
      final space = spaces.where((w) => w.id == entry.key).firstOrNull;
      content.add(
        group(
          'work-${entry.key}',
          ssh
              ? profile?.name ?? 'SSH 配置已失效'
              : space?.name ??
                    (entry.key == defaultDesktopWorkspaceId
                        ? '默认工作区'
                        : '本机位置已失效'),
          entry.value,
          type: ssh
              ? 'SSH · ${profile?.host ?? '配置不可用'} · ${entry.value.isEmpty ? '' : policies[entry.value.first.id]?.remoteRoot ?? ''}'
              : '本机 · ${space?.root ?? ''}',
          onNew: () => _newProjectChat(
            workspaceId: ssh ? null : entry.key,
            workMode: true,
            sshProfileId: ssh ? entry.key.substring(4) : null,
            remoteRoot: entry.value.isEmpty
                ? null
                : policies[entry.value.first.id]?.remoteRoot,
          ),
        ),
      );
    }
    content.add(const _SidebarSectionLabel('聊天'));
    final chatGroups = <String, List<Conversation>>{};
    for (final c in chats) {
      (chatGroups[c.projectId ?? ''] ??= []).add(c);
    }
    chatGroups.putIfAbsent('', () => []);
    final orderedChats = chatGroups.entries.toList()
      ..sort(
        (a, b) => b.value.isEmpty
            ? -1
            : a.value.isEmpty
            ? 1
            : visible
                  .indexOf(a.value.first)
                  .compareTo(visible.indexOf(b.value.first)),
      );
    for (final entry in orderedChats) {
      content.add(
        group(
          'chat-${entry.key}',
          projects.where((p) => p.id == entry.key).firstOrNull?.name ??
              (entry.key.isEmpty ? '未引用资料集' : '资料集'),
          entry.value,
          onNew: () => _newProjectChat(
            projectId: entry.key.isEmpty ? null : entry.key,
            workMode: false,
          ),
        ),
      );
    }
    final stories = visible.where((c) => c.isStoryLike).toList();
    if ((settings?.creationModeEnabled ?? true) && stories.isNotEmpty) {
      content.add(
        group(
          'creation',
          '创作',
          stories,
          onNew: () => destination(ShellTab.studio),
        ),
      );
    }
    final study = visible.where((c) => c.isStudy).toList();
    if ((settings?.studyModeEnabled ?? true) && study.isNotEmpty) {
      content.add(
        group('study', '学习', study, onNew: () => destination(ShellTab.study)),
      );
    }
    final pendingIds = {
      ...approvals.map((a) => a.conversationId),
      ...questions.map((q) => q.conversationId),
    };
    final hooks = ref.watch(workHooksProvider);
    final selected = ref.watch(shellTabProvider).navigationTab;
    return MouseRegion(
      onEnter: (_) {
        _frozenOrder = visible.map((c) => c.id).toList();
        _hovering = true;
      },
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: proto.panel,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/branding/assistant.png',
                        width: 26,
                        height: 26,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Expert Chat',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: proto.ink,
                          ),
                        ),
                      ),
                      if (widget.onCollapse != null)
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: PrototypeIconButton(
                            icon: Icons.view_sidebar_outlined,
                            onPressed: widget.onCollapse,
                            tooltip: '收起侧边栏',
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: widget.desktopMode ? 36 : 44,
                        decoration: BoxDecoration(
                          color: proto.surface,
                          border: Border.all(color: proto.line),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Tooltip(
                                message: '搜索会话',
                                child: InkWell(
                                  onTap: () => setState(() {
                                    _desktopSearchOpen = !_desktopSearchOpen;
                                    if (!_desktopSearchOpen) {
                                      _history.setQuery('');
                                    }
                                  }),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Text(
                                          _showArchived ? '搜索已归档' : '搜索',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: proto.faint,
                                          ),
                                        ),
                                        const Spacer(),
                                        LineIcon(
                                          Icons.search,
                                          size: 14,
                                          color: proto.faint,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _historyMenu(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      key: const ValueKey('sidebar-new-chat'),
                      width: widget.desktopMode ? 36 : 44,
                      height: widget.desktopMode ? 36 : 44,
                      decoration: BoxDecoration(
                        color: proto.surface,
                        border: Border.all(color: proto.line),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: PrototypeIconButton(
                        icon: Icons.edit_square,
                        onPressed: () => _newProjectChat(workMode: false),
                        tooltip: '新聊天',
                      ),
                    ),
                  ],
                ),
                _sessionControls(visible),
                if (_desktopSearchOpen)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                      key: const ValueKey('conversation-search-field'),
                      autofocus: true,
                      onChanged: _history.setQuery,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: '搜索聊天和工作',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: _history.searching
                      ? const Center(child: Text('正在搜索…'))
                      : _history.error != null
                      ? PrototypeButton(
                          label: _history.error!,
                          onPressed: _history.retry,
                          small: true,
                        )
                      : ListView(
                          key: const ValueKey('desktop-project-conversations'),
                          padding: const EdgeInsets.only(top: 10),
                          children: [
                            for (var i = 0; i < content.length; i++) ...[
                              if (i > 0) const SizedBox(height: 10),
                              content[i],
                            ],
                          ],
                        ),
                ),
                Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: proto.line)),
                  ),
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListenableBuilder(
                        listenable: runtimeListenable(hooks),
                        builder: (_, _) => _SidebarDestination(
                          key: const ValueKey('sidebar-automation'),
                          label: '自动化',
                          icon: Icons.autorenew,
                          selected: selected == ShellTab.automation,
                          desktop: widget.desktopMode,
                          trailing:
                              '${hooks.records.where((r) => r.definition.enabled).length + remoteCounts.values.whereType<int>().fold(0, (a, b) => a + b)}${remoteCounts.isEmpty || remoteCounts.values.any((v) => v == null) ? ' · 远程未知' : ' 条已启用'}',
                          onTap: () => destination(ShellTab.automation),
                        ),
                      ),
                      _SidebarDestination(
                        key: const ValueKey('sidebar-resources'),
                        label: '资料库',
                        icon: Icons.article_outlined,
                        selected: selected == ShellTab.resources,
                        desktop: widget.desktopMode,
                        onTap: () => destination(ShellTab.resources),
                      ),
                      _SidebarDestination(
                        label: '设置',
                        icon: Icons.settings_outlined,
                        selected: selected == ShellTab.settings,
                        desktop: widget.desktopMode,
                        onTap: () => destination(ShellTab.settings),
                      ),
                      if (pendingIds.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: PrototypeButton(
                            label:
                                '${[if (approvals.isNotEmpty) '${approvals.length} 个操作等你批准', if (questions.isNotEmpty) '${questions.length} 个问题等回答'].join(' · ')} →',
                            small: true,
                            expand: true,
                            variant: PrototypeButtonVariant.danger,
                            onPressed: () async {
                              await ref
                                  .read(chatControllerProvider.notifier)
                                  .selectConversation(pendingIds.first);
                              destination(ShellTab.chat);
                            },
                          ),
                        ),
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

  Future<void> _manageWorkspaces() async {
    await Navigator.of(context).push(
      applicationSurfaceRoute<void>(
        context,
        (_) => const DesktopWorkspacesPage(),
        title: '管理执行位置',
      ),
    );
    if (!mounted) return;
    ref.invalidate(registeredDesktopWorkspacesProvider);
    ref.invalidate(desktopWorkspacesProvider);
  }

  Future<void> _newProjectChat({
    String? workspaceId,
    String? projectId,
    bool workMode = false,
    String? sshProfileId,
    String? remoteRoot,
  }) async {
    setState(() => _showArchived = false);
    final epoch = ++_navigationEpoch;
    final controller = ref.read(chatControllerProvider.notifier);
    controller.newConversation(
      projectId: projectId,
      workMode: workMode,
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
          AppToastMessenger.of(
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
    if (conversationId != null && sshProfileId != null) {
      final policy =
          ref.read(sessionPolicyProvider)[conversationId] ??
          const SessionPolicy();
      await ref
          .read(sessionPolicyProvider.notifier)
          .save(
            conversationId,
            policy.copyWith(sshProfileId: sshProfileId, remoteRoot: remoteRoot),
          );
    }
    if (mounted) {
      openShellTab(ref, ShellTab.chat);
      _closeDrawerIfAny();
    }
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: PrototypeColors.of(context).faint,
      ),
    ),
  );
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.desktop,
    required this.onTap,
    this.trailing,
  });
  final String label;
  final IconData icon;
  final bool selected, desktop;
  final VoidCallback onTap;
  final String? trailing;
  @override
  Widget build(BuildContext context) {
    final c = PrototypeColors.of(context);
    return Material(
      color: selected ? c.surface : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: desktop ? 36 : 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                LineIcon(icon, size: 16, color: c.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                      color: c.ink,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: TextStyle(fontSize: 11, color: c.muted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
