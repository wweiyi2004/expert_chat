import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/conversation_repository.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../settings/prompt_presets_page.dart';
import '../shell/shell_tab.dart';
import '../library/resources_page.dart';
import 'controllers/conversation_sidebar_controller.dart';
import 'jump_to_message.dart';
import 'widgets/conversation_history_list.dart';
import 'widgets/conversation_mode_filter.dart';

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
  });

  final String id;
  final String title;
  final ConversationMode mode;

  @override
  bool operator ==(Object other) =>
      other is _HistoryItemSlice &&
      id == other.id &&
      title == other.title &&
      mode == other.mode;

  @override
  int get hashCode => Object.hash(id, title, mode);
}

/// Shared workspace navigation and conversation history for shell and drawer.
class ChatWorkspaceSidebar extends ConsumerStatefulWidget {
  const ChatWorkspaceSidebar({super.key, this.onCollapse});

  final VoidCallback? onCollapse;

  @override
  ConsumerState<ChatWorkspaceSidebar> createState() =>
      _ChatWorkspaceSidebarState();
}

class _ChatWorkspaceSidebarState extends ConsumerState<ChatWorkspaceSidebar> {
  late final ConversationSidebarController _history;
  int _navigationEpoch = 0;
  String? _renamingId; // id of the conversation being renamed inline
  final _renameCtrl = TextEditingController();
  @override
  void initState() {
    super.initState();
    _history = ConversationSidebarController(
      search: (query) =>
          ref.read(conversationRepositoryProvider).searchMessages(query),
    )..addListener(_onHistoryChanged);
  }

  void _onHistoryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
              _HistoryItemSlice(id: c.id, title: c.title, mode: c.mode),
          ],
        );
      }),
    );
    final state = ref.read(chatControllerProvider).value;
    final selectedTab = ref.watch(shellTabProvider);
    final settings = ref.watch(settingsControllerProvider).value;
    final workspaceTabs = ShellTab.visible(
      researchModeEnabled: settings?.researchModeEnabled ?? false,
      studyModeEnabled: settings?.studyModeEnabled ?? true,
      creationModeEnabled: settings?.creationModeEnabled ?? true,
    ).where((tab) => tab != ShellTab.settings).toList();
    final all = state?.conversations ?? const <Conversation>[];
    final visible = [
      for (final c in all)
        if (_history.matches(c)) c,
    ];

    void openWorkspace(ShellTab tab) {
      ++_navigationEpoch;
      openShellTab(ref, tab);
      _closeDrawerIfAny();
    }

    void newConversation() {
      controller.newConversation();
      openWorkspace(ShellTab.chat);
    }

    // Header remains fixed while the recent conversation list scrolls.
    final header = Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.98),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
            child: Row(
              children: [
                Image.asset(
                  'assets/branding/assistant.png',
                  width: 34,
                  height: 34,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Expert Chat',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                if (widget.onCollapse != null)
                  IconButton(
                    tooltip: '收起侧边栏',
                    onPressed: widget.onCollapse,
                    icon: const Icon(Icons.menu_open_rounded),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              key: const ValueKey('conversation-search-field'),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 19),
                hintText: '搜索会话',
                filled: true,
                fillColor: scheme.surfaceContainer,
              ),
              onChanged: _history.setQuery,
            ),
          ),
          ...[
            ListTile(
              key: const ValueKey('sidebar-resources'),
              leading: const Icon(Icons.folder_outlined),
              title: const Text('资料库'),
              onTap: () {
                _closeDrawerIfAny();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ResourcesPage(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmarks_outlined),
              title: const Text('提示词预设'),
              onTap: () {
                _closeDrawerIfAny();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PromptPresetsPage(),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
              child: Column(
                children: [
                  for (final tab in workspaceTabs)
                    _WorkspaceDestination(
                      tab: tab,
                      selected: selectedTab == tab,
                      onTap: () => openWorkspace(tab),
                    ),
                ],
              ),
            ),
          ],
          const _SidebarSectionLabel('最近会话'),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: ConversationModeFilter(
              selected: _history.mode,
              onSelected: _history.setMode,
            ),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.85),
          ),
        ],
      ),
    );

    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.92),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: NestedScrollView(
                headerSliverBuilder: (context, scrolled) => [
                  SliverToBoxAdapter(child: header),
                ],
                body: _history.searching
                    ? const Center(child: Text('正在搜索…'))
                    : _history.error != null
                    ? Center(
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
                      )
                    : ConversationHistoryList(
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
            ),
            ...[
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.72),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('sidebar-new-chat'),
                        onPressed: newConversation,
                        icon: const Icon(Icons.edit_square),
                        label: const Text('新对话'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filledTonal(
                      tooltip: '设置',
                      onPressed: () => openWorkspace(ShellTab.settings),
                      icon: const Icon(Icons.person_outline_rounded),
                    ),
                  ],
                ),
              ),
            ],
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
