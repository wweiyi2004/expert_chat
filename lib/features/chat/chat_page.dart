import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models.dart';
import '../../domain/export/conversation_export.dart';
import '../../state/chat_controller.dart';
import '../settings/settings_page.dart';
import 'widgets/attachment_chip.dart';
import 'widgets/message_bubble.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Attachment> _attachments = [];
  bool _picking = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    final attachments = List<Attachment>.of(_attachments);
    _input.clear();
    setState(_attachments.clear);
    ref
        .read(chatControllerProvider.notifier)
        .sendMessage(text, attachments: attachments);
    _scrollToBottom();
  }

  Future<void> _pickFiles() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const [
          'pdf',
          'docx',
          'xlsx',
          'pptx',
          'txt',
          'md',
          'csv',
          'json',
        ],
      );
      if (result == null) return;
      final parser = ref.read(fileParserProvider);
      for (final f in result.files) {
        final bytes = f.bytes;
        if (bytes == null) continue;
        final attachment = parser.parse(
          name: f.name,
          mimeType: _mimeFor(f.extension),
          sizeBytes: f.size,
          bytes: bytes,
        );
        _attachments.add(attachment);
      }
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  String _mimeFor(String? ext) => switch (ext?.toLowerCase()) {
    'pdf' => 'application/pdf',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'md' => 'text/markdown',
    _ => 'text/plain',
  };

  void _removeAttachment(String id) {
    setState(() => _attachments.removeWhere((a) => a.id == id));
  }

  Future<void> _export(Conversation? convo) async {
    if (convo == null || convo.messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前对话为空，无法导出'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    try {
      final path = await ConversationExport.saveMarkdown(convo);
      if (path != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已导出到 $path'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败：$e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Two-pane history is shown at/above this width; narrower uses a drawer.
  static const double _twoPaneBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(chatControllerProvider);
    final controller = ref.read(chatControllerProvider.notifier);
    final current = asyncState.value?.current;

    // Auto-scroll as content streams in.
    ref.listen(chatControllerProvider, (_, _) => _scrollToBottom());

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            controller.newConversation,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            controller.newConversation,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final twoPane = constraints.maxWidth >= _twoPaneBreakpoint;
            final scheme = Theme.of(context).colorScheme;
            return Scaffold(
              appBar: AppBar(
                titleSpacing: twoPane ? 20 : 8,
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 16,
                        color: scheme.onPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text('Expert Chat'),
                  ],
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(1),
                  child: Container(height: 1, color: scheme.outlineVariant),
                ),
                actions: [
                  IconButton(
                    tooltip: '新对话 (Ctrl+N)',
                    icon: const Icon(Icons.add_comment_outlined),
                    onPressed: controller.newConversation,
                  ),
                  IconButton(
                    tooltip: '导出当前对话',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => _export(current),
                  ),
                  IconButton(
                    tooltip: '设置',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsPage()),
                    ),
                  ),
                ],
              ),
              drawer: twoPane ? null : _HistoryDrawer(asyncState: asyncState),
              body: Row(
                children: [
                  if (twoPane)
                    SizedBox(
                      width: 300,
                      child: _HistoryPanel(asyncState: asyncState),
                    ),
                  if (twoPane) const VerticalDivider(width: 1),
                  Expanded(
                    child: asyncState.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(child: Text('出错了：$e')),
                      data: (state) => _chatColumn(state, controller),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chatColumn(ChatState state, ChatController controller) {
    final convo = state.current;
    final messages = convo?.activePath ?? const <ChatMessage>[];
    return Column(
      children: [
        if (state.error != null)
          _ErrorBanner(
            message: state.error!,
            onRetry: state.isStreaming ? null : () => controller.retryLast(),
          ),
        Expanded(
          child: messages.isEmpty
              ? const _EmptyState()
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
                      itemCount: messages.length,
                      itemBuilder: (context, i) {
                        final m = messages[i];
                        final isLast = i == messages.length - 1;
                        final isLastAssistant =
                            isLast && m.role == MessageRole.assistant;
                        final (bIdx, bCount) = convo!.branchInfo(m.id);
                        return MessageBubble(
                          message: m,
                          isStreaming: state.isStreaming && isLastAssistant,
                          onRegenerate: (isLastAssistant && !state.isStreaming)
                              ? controller.regenerate
                              : null,
                          onEdit:
                              (m.role == MessageRole.user && !state.isStreaming)
                              ? (text) => controller.editMessage(m.id, text)
                              : null,
                          branchIndex: bIdx,
                          branchCount: bCount,
                          onPrevBranch: () => controller.switchBranch(m.id, -1),
                          onNextBranch: () => controller.switchBranch(m.id, 1),
                        );
                      },
                    ),
                  ),
                ),
        ),
        _Composer(
          controller: _input,
          isStreaming: state.isStreaming,
          deepThink: state.deepThink,
          searchEnabled: state.searchEnabled,
          isSearching: state.isSearching,
          attachments: _attachments,
          picking: _picking,
          onToggleDeepThink: controller.toggleDeepThink,
          onToggleSearch: controller.toggleSearch,
          onPickFiles: _pickFiles,
          onRemoveAttachment: _removeAttachment,
          onSend: _send,
          onStop: controller.stop,
        ),
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.isStreaming,
    required this.deepThink,
    required this.searchEnabled,
    required this.isSearching,
    required this.attachments,
    required this.picking,
    required this.onToggleDeepThink,
    required this.onToggleSearch,
    required this.onPickFiles,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool isStreaming;
  final bool deepThink;
  final bool searchEnabled;
  final bool isSearching;
  final List<Attachment> attachments;
  final bool picking;
  final VoidCallback onToggleDeepThink;
  final VoidCallback onToggleSearch;
  final VoidCallback onPickFiles;
  final ValueChanged<String> onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.06),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final a in attachments)
                              AttachmentChip(
                                attachment: a,
                                onRemove: () => onRemoveAttachment(a.id),
                              ),
                          ],
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.enter,
                              ): () {
                                if (!isStreaming) onSend();
                              },
                            },
                            child: TextField(
                              controller: controller,
                              minLines: 1,
                              maxLines: 6,
                              textInputAction: TextInputAction.newline,
                              decoration: const InputDecoration(
                                hintText: '给 Expert Chat 发消息...',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        isStreaming
                            ? IconButton.filled(
                                onPressed: onStop,
                                icon: const Icon(Icons.stop),
                                tooltip: '停止',
                                style: IconButton.styleFrom(
                                  fixedSize: const Size.square(40),
                                  backgroundColor: scheme.errorContainer,
                                  foregroundColor: scheme.onErrorContainer,
                                ),
                              )
                            : IconButton.filled(
                                onPressed: onSend,
                                icon: const Icon(Icons.arrow_upward),
                                tooltip: '发送',
                                style: IconButton.styleFrom(
                                  fixedSize: const Size.square(40),
                                  backgroundColor: scheme.primary,
                                  foregroundColor: scheme.onPrimary,
                                ),
                              ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        IconButton(
                          onPressed: (isStreaming || picking)
                              ? null
                              : onPickFiles,
                          tooltip: '上传文件（PDF / Word / Excel / PPT / 文本）',
                          icon: picking
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.attach_file),
                          style: IconButton.styleFrom(
                            fixedSize: const Size.square(34),
                            backgroundColor: scheme.surfaceContainerHighest,
                            foregroundColor: scheme.primary,
                          ),
                        ),
                        FilterChip(
                          selected: deepThink,
                          showCheckmark: false,
                          avatar: Icon(
                            Icons.psychology_outlined,
                            size: 18,
                            color: deepThink
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          label: const Text('深度思考'),
                          tooltip: '开启后本次对话使用深度推理模型',
                          onSelected: (_) => onToggleDeepThink(),
                        ),
                        FilterChip(
                          selected: searchEnabled,
                          showCheckmark: false,
                          avatar: Icon(
                            Icons.travel_explore,
                            size: 18,
                            color: searchEnabled
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          label: const Text('联网'),
                          tooltip: '开启后允许模型按需调用 web_search（需在设置中配置搜索 Key）',
                          onSelected: (_) => onToggleSearch(),
                        ),
                        if (isSearching)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 13,
                                  height: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: scheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '正在联网搜索',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryDrawer extends StatelessWidget {
  const _HistoryDrawer({required this.asyncState});
  final AsyncValue<ChatState> asyncState;

  @override
  Widget build(BuildContext context) =>
      Drawer(child: _HistoryPanel(asyncState: asyncState));
}

class _HistoryPanel extends ConsumerStatefulWidget {
  const _HistoryPanel({required this.asyncState});
  final AsyncValue<ChatState> asyncState;

  @override
  ConsumerState<_HistoryPanel> createState() => _HistoryPanelState();
}

class _HistoryPanelState extends ConsumerState<_HistoryPanel> {
  String _query = '';
  String? _renamingId; // id of the conversation being renamed inline
  final _renameCtrl = TextEditingController();

  @override
  void dispose() {
    _renameCtrl.dispose();
    super.dispose();
  }

  bool _matches(Conversation c, String q) {
    if (q.isEmpty) return true;
    final lower = q.toLowerCase();
    if (c.title.toLowerCase().contains(lower)) return true;
    return c.messages.any((m) => m.content.toLowerCase().contains(lower));
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
    final state = widget.asyncState.value;
    final all = state?.conversations ?? const <Conversation>[];
    final visible = [
      for (final c in all)
        if (_matches(c, _query)) c,
    ];

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '历史对话',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: '搜索对话…',
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(
                      child: Text('没有匹配的对话', style: TextStyle(fontSize: 13)),
                    )
                  : ListView(
                      children: [
                        for (final c in visible)
                          if (c.id == _renamingId)
                            // Inline rename — no occluding dialog.
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: ListTile(
                                tileColor: scheme.surfaceContainer,
                                leading: const Icon(Icons.chat_bubble_outline),
                                title: TextField(
                                  controller: _renameCtrl,
                                  autofocus: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                  ),
                                  onSubmitted: (_) => _commitRename(),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.check, size: 20),
                                  tooltip: '保存',
                                  onPressed: _commitRename,
                                ),
                              ),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: ListTile(
                                selected: c.id == state?.currentId,
                                tileColor: scheme.surfaceContainer,
                                leading: const Icon(Icons.chat_bubble_outline),
                                title: Text(
                                  c.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_horiz, size: 20),
                                  onSelected: (v) {
                                    if (v == 'rename') _startRename(c);
                                    if (v == 'delete') {
                                      controller.deleteConversation(c.id);
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'rename',
                                      child: Text('重命名'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除'),
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  controller.selectConversation(c.id);
                                  _closeDrawerIfAny();
                                },
                              ),
                            ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          if (onRetry != null)
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_outlined, size: 48, color: scheme.primary),
          const SizedBox(height: 16),
          Text('开始一段对话', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            '在下方输入消息，或在设置中配置 API Key',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
