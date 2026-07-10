import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/models.dart';
import '../../domain/export/conversation_export.dart';
import '../../domain/tools/file_parser.dart';
import '../../domain/tools/local_file_reader.dart';
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

  // Keep an accidental multi-select from consuming the device's memory,
  // context window, or API request budget. The parser additionally enforces
  // format-specific limits before it extracts content.
  static const int _maxAttachments = 5;
  static const int _maxAttachmentBytes = 10 * 1024 * 1024;
  static const int _maxTotalAttachmentBytes = 20 * 1024 * 1024;

  /// Whether the view should keep following new content (stick-to-bottom). Set
  /// false the moment the user scrolls up, so streaming output no longer yanks
  /// them back down; restored when they scroll back to the bottom (or tap the
  /// jump button / send a message).
  bool _stick = true;

  /// How close to the bottom (px) still counts as "at the bottom".
  static const double _stickThreshold = 80;

  /// True while we are driving an animated scroll ourselves, so [_onScroll]
  /// doesn't mistake the in-flight animation for the user scrolling away.
  bool _programmaticScroll = false;

  /// Streaming state changes can arrive several times per frame. Coalesce the
  /// resulting post-frame scroll work into one operation so rendering remains
  /// smooth on lower-end Android devices and long conversations.
  bool _scrollScheduled = false;
  bool _pendingAnimatedScroll = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Re-evaluate stick-to-bottom whenever the user scrolls. Programmatic
  /// auto-scrolls also fire this, which simply keeps [_stick] true at the bottom.
  void _onScroll() {
    if (!_scroll.hasClients || _programmaticScroll) return;
    final pos = _scroll.position;
    final atBottom = pos.maxScrollExtent - pos.pixels <= _stickThreshold;
    if (atBottom != _stick) setState(() => _stick = atBottom);
  }

  /// Resume following and snap to the latest content (jump button / send).
  void _jumpToBottom() {
    setState(() => _stick = true);
    _scrollToBottom(animated: true);
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    final attachments = List<Attachment>.of(_attachments);
    _input.clear();
    setState(_attachments.clear);
    _jumpToBottom();
    final accepted = await ref
        .read(chatControllerProvider.notifier)
        .sendMessage(text, attachments: attachments);
    // Rejected (e.g. API key 未配置 / 正在生成中) → restore the draft so the
    // user's input isn't lost. Only restore when the field is still empty, so
    // we don't clobber anything the user started typing during the await.
    if (!accepted && mounted && _input.text.isEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
      setState(() => _attachments.addAll(attachments));
    }
  }

  Future<void> _pickFiles() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: false,
        withReadStream: true,
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
          'png',
          'jpg',
          'jpeg',
          'gif',
          'webp',
          'bmp',
        ],
      );
      if (result == null) return;

      final slots = _maxAttachments - _attachments.length;
      if (slots <= 0) {
        _showAttachmentNotice('最多可添加 $_maxAttachments 个附件。');
        return;
      }

      final parser = ref.read(fileParserProvider);
      final additions = <Attachment>[];
      var runningTotal = _attachments.fold<int>(
        0,
        (total, attachment) => total + attachment.sizeBytes,
      );
      var tooMany = 0;
      var tooLarge = 0;
      var overTotal = 0;
      var unreadable = 0;
      for (final f in result.files) {
        if (additions.length >= slots) {
          tooMany++;
          continue;
        }
        if (f.size > _maxAttachmentBytes) {
          tooLarge++;
          continue;
        }
        final stream = f.readStream ?? openLocalFileReadStream(f.path);
        if (stream == null) {
          unreadable++;
          continue;
        }
        final remainingTotal = _maxTotalAttachmentBytes - runningTotal;
        if (remainingTotal <= 0) {
          overTotal++;
          continue;
        }
        final readLimit = remainingTotal < _maxAttachmentBytes
            ? remainingTotal
            : _maxAttachmentBytes;
        final Uint8List bytes;
        try {
          bytes = await FileParser.readBytesWithLimit(
            stream,
            maxBytes: readLimit,
          );
        } on FileReadLimitExceeded {
          if (readLimit < _maxAttachmentBytes) {
            overTotal++;
          } else {
            tooLarge++;
          }
          continue;
        } catch (_) {
          unreadable++;
          continue;
        }
        // Prefer the actual bytes when a platform picker reports an inaccurate
        // size (or a provider returns a synthetic file).
        final sizeBytes = f.size > bytes.lengthInBytes
            ? f.size
            : bytes.lengthInBytes;
        if (sizeBytes > _maxAttachmentBytes) {
          tooLarge++;
          continue;
        }
        if (runningTotal + sizeBytes > _maxTotalAttachmentBytes) {
          overTotal++;
          continue;
        }
        final attachment = await parser.parseAsync(
          name: f.name,
          mimeType: _mimeFor(f.extension),
          sizeBytes: sizeBytes,
          bytes: bytes,
        );
        if (!mounted) return;
        additions.add(attachment);
        runningTotal += sizeBytes;
      }
      if (additions.isNotEmpty && mounted) {
        setState(() => _attachments.addAll(additions));
      }
      final notices = <String>[];
      if (additions.isNotEmpty) notices.add('已添加 ${additions.length} 个附件');
      if (tooMany > 0) notices.add('跳过 $tooMany 个（最多 $_maxAttachments 个）');
      if (tooLarge > 0) {
        notices.add('跳过 $tooLarge 个（单个最大 10 MB）');
      }
      if (overTotal > 0) notices.add('跳过 $overTotal 个（总计最大 20 MB）');
      if (unreadable > 0) notices.add('跳过 $unreadable 个（无法读取）');
      if (notices.isNotEmpty) _showAttachmentNotice(notices.join('；'));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _showAttachmentNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _mimeFor(String? ext) => switch (ext?.toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
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

  /// Follow the latest content. Streaming uses an instant [jumpTo] so there is
  /// no animation window in which [_onScroll] could read a not-at-bottom
  /// position and wrongly unstick; explicit user jumps animate for polish.
  void _scrollToBottom({bool animated = false}) {
    // Only follow when the user is parked at the bottom; if they've scrolled up
    // to read, leave their position alone.
    if (!_stick) return;
    _pendingAnimatedScroll = _pendingAnimatedScroll || animated;
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      final shouldAnimate = _pendingAnimatedScroll;
      _pendingAnimatedScroll = false;
      if (!mounted || !_stick || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if ((_scroll.position.pixels - target).abs() < 0.5) return;
      if (shouldAnimate) {
        _programmaticScroll = true;
        _scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            )
            .whenComplete(() => _programmaticScroll = false);
      } else {
        _scroll.jumpTo(target);
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

    // Auto-scroll as content streams in (only while stuck to the bottom).
    // Switching conversations resumes following and snaps to the latest turn.
    ref.listen(chatControllerProvider, (prev, next) {
      if (prev?.value?.currentId != next.value?.currentId) _stick = true;
      _scrollToBottom();
    });

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
                        borderRadius: BorderRadius.circular(10),
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
    // Whether the in-flight generation (if any) belongs to THIS conversation;
    // another conversation's stream must not light up bubbles here.
    final streamingHere = convo != null && state.streamingConvoId == convo.id;
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
              : Stack(
                  children: [
                    Center(
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
                              // Keyed by message id: bubbles hold local edit
                              // state that must not leak across messages when
                              // the list shifts (branch switch, new turns).
                              key: ValueKey(m.id),
                              message: m,
                              isStreaming: streamingHere && isLastAssistant,
                              onRegenerate:
                                  (isLastAssistant && !state.isStreaming)
                                  ? controller.regenerate
                                  : null,
                              onEdit:
                                  (m.role == MessageRole.user &&
                                      !state.isStreaming)
                                  ? (text) => controller.editMessage(m.id, text)
                                  : null,
                              branchIndex: bIdx,
                              branchCount: bCount,
                              onPrevBranch: () =>
                                  controller.switchBranch(m.id, -1),
                              onNextBranch: () =>
                                  controller.switchBranch(m.id, 1),
                            );
                          },
                        ),
                      ),
                    ),
                    // Shown only when the user has scrolled away from the
                    // bottom; tapping resumes follow + snaps to the latest.
                    if (!_stick)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 12,
                        child: Center(
                          child: _JumpToBottomButton(onTap: _jumpToBottom),
                        ),
                      ),
                  ],
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
                                // Don't fire while an IME composition (拼音
                                // 候选) is in progress — that Enter belongs to
                                // the input method, not "send".
                                if (!isStreaming &&
                                    !controller.value.composing.isValid) {
                                  onSend();
                                }
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
                                  fixedSize: const Size.square(48),
                                  backgroundColor: scheme.errorContainer,
                                  foregroundColor: scheme.onErrorContainer,
                                ),
                              )
                            : IconButton.filled(
                                onPressed: onSend,
                                icon: const Icon(Icons.arrow_upward),
                                tooltip: '发送',
                                style: IconButton.styleFrom(
                                  fixedSize: const Size.square(48),
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
                          tooltip: '上传文件（最多 5 个，单个最大 10 MB）',
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
                            fixedSize: const Size.square(48),
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
                          tooltip:
                              '开启后模型可按需联网搜索；默认用免费 DuckDuckGo（无需 Key），'
                              '也可在设置中改用 Tavily / Exa / 博查 等带 Key 的后端',
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
                              borderRadius: BorderRadius.circular(12),
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
  Timer? _searchDebounce;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _renameCtrl.dispose();
    super.dispose();
  }

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value.trim());
    });
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
      ref
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
                onChanged: _scheduleSearch,
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(
                      child: Text('没有匹配的对话', style: TextStyle(fontSize: 13)),
                    )
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final c = visible[index];
                        if (c.id == _renamingId) {
                          // Inline rename — no occluding dialog.
                          return Padding(
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
                          );
                        }
                        return Padding(
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
                                if (v == 'delete') _confirmDelete(c);
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('重命名'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(
                                    '删除',
                                    style: TextStyle(color: scheme.error),
                                  ),
                                ),
                              ],
                            ),
                            onTap: () {
                              controller.selectConversation(c.id);
                              _closeDrawerIfAny();
                            },
                          ),
                        );
                      },
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

/// Small circular "back to latest" affordance, shown over the message list
/// while the user has scrolled up during streaming.
class _JumpToBottomButton extends StatelessWidget {
  const _JumpToBottomButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '回到最新消息',
      child: Tooltip(
        message: '回到最新消息',
        child: Material(
          color: scheme.surfaceContainerHighest,
          elevation: 2,
          shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Icon(
                Icons.arrow_downward,
                size: 20,
                color: scheme.primary,
              ),
            ),
          ),
        ),
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
