import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/mode_style.dart';
import '../../core/providers.dart';
import '../../core/workspace_layout.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../data/ui_prefs.dart';
import '../../domain/context/context_window_manager.dart';
import '../../domain/export/conversation_export.dart';
import '../../domain/tools/file_parser.dart';
import '../../domain/tools/local_file_reader.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import '../story/director_story_setup_page.dart';
import '../story/ensemble_setup_page.dart';
import '../story/story_panel.dart';
import 'jump_to_message.dart';
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
  bool _imageMode = false;

  /// Wide-layout tools pane (story / ensemble plot). Ignored on phone.
  bool _toolsOpen = true;

  /// Wide-layout history pane toggle (desktop).
  bool _historyOpen = true;
  double _historyWidth = WorkspacePaneDefaults.historyWidth;
  double _toolsWidth = WorkspacePaneDefaults.toolsWidth;

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

  /// Multi-select share mode (long-press / secondary-click on a bubble).
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _enterSelect(String messageId) {
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(messageId);
    });
  }

  void _toggleSelect(String messageId) {
    setState(() {
      if (_selectedIds.contains(messageId)) {
        _selectedIds.remove(messageId);
        if (_selectedIds.isEmpty) _selecting = false;
      } else {
        _selectedIds.add(messageId);
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  List<ChatMessage> _selectedOrdered(List<ChatMessage> path) => [
    for (final m in path)
      if (_selectedIds.contains(m.id)) m,
  ];

  Future<void> _shareSelected(List<ChatMessage> path, Conversation? convo) async {
    final selected = _selectedOrdered(path);
    if (selected.isEmpty) return;
    final md = ConversationExport.messagesToMarkdown(
      selected,
      title: convo?.title ?? '所选消息',
      directorMode: convo?.localCast.isNotEmpty ?? false,
    );
    try {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}${Platform.pathSeparator}expert-chat-share.md',
        );
        await file.writeAsString(md, encoding: utf8);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'text/markdown')],
            subject: convo?.title ?? 'Expert Chat',
          ),
        );
      } else {
        await SharePlus.instance.share(
          ShareParams(text: md, subject: convo?.title ?? 'Expert Chat'),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('分享失败：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _copySelectedMarkdown(List<ChatMessage> path, Conversation? convo) async {
    final selected = _selectedOrdered(path);
    if (selected.isEmpty) return;
    final md = ConversationExport.messagesToMarkdown(
      selected,
      title: convo?.title ?? '所选消息',
      directorMode: convo?.localCast.isNotEmpty ?? false,
    );
    await Clipboard.setData(ClipboardData(text: md));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 ${selected.length} 条为 Markdown'),
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  /// Scroll so [messageId] is near the top of the viewport (search jump).
  void _scrollToMessage(String messageId) {
    final ctx = _messageKeys[messageId]?.currentContext;
    if (ctx == null) return;
    setState(() => _stick = false);
    _programmaticScroll = true;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.08,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    ).whenComplete(() {
      _programmaticScroll = false;
    });
  }

  final Map<String, GlobalKey> _messageKeys = {};

  GlobalKey _keyForMessage(String id) =>
      _messageKeys.putIfAbsent(id, GlobalKey.new);

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty && _attachments.isEmpty) return;
    final settings = ref.read(settingsControllerProvider).value;
    final useImageGeneration =
        _imageMode && (settings?.imageGenerationConfigured ?? false);
    if (useImageGeneration && _attachments.isNotEmpty) {
      _showAttachmentNotice('生图模式暂不支持附件，请先移除附件。');
      return;
    }
    final attachments = List<Attachment>.of(_attachments);
    _input.clear();
    setState(_attachments.clear);
    _jumpToBottom();
    final chat = ref.read(chatControllerProvider.notifier);
    final accepted = useImageGeneration
        ? await chat.generateImage(text)
        : await chat.sendMessage(text, attachments: attachments);
    // Rejected (e.g. API key 未配置 / 正在生成中) → restore the draft so the
    // user's input isn't lost. Only restore when the field is still empty, so
    // we don't clobber anything the user started typing during the await.
    if (!accepted && mounted && _input.text.isEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
      setState(() => _attachments.addAll(attachments));
    }
  }

  static const _documentExtensions = [
    'pdf',
    'docx',
    'xlsx',
    'pptx',
    'txt',
    'md',
    'csv',
    'json',
  ];
  static const _imageExtensions = [
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
  ];

  Future<void> _pickDocuments() => _pickFiles(imagesOnly: false);

  Future<void> _pickImages() => _pickFiles(imagesOnly: true);

  Future<void> _pickFiles({required bool imagesOnly}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final visionOk =
          ref.read(settingsControllerProvider).value?.visionConfigured ?? false;
      if (imagesOnly && !visionOk) {
        _showAttachmentNotice('请先在设置中配置视觉 API，再上传图片。');
        return;
      }
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: false,
        withReadStream: true,
        type: FileType.custom,
        allowedExtensions: imagesOnly
            ? _imageExtensions
            : [
                ..._documentExtensions,
                if (visionOk) ..._imageExtensions,
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

  void _toggleImageMode() {
    if (!_imageMode && _attachments.isNotEmpty) {
      _showAttachmentNotice('请先移除附件，再进入生图模式。');
      return;
    }
    setState(() => _imageMode = !_imageMode);
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
      String? characterName;
      if (convo.isStory && convo.characterId != null) {
        final card = await ref
            .read(characterRepositoryProvider)
            .getById(convo.characterId!);
        characterName = card?.name;
      }
      final path = await ConversationExport.saveMarkdown(
        convo,
        characterName: characterName,
      );
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

  String? _characterNameFor(Conversation? convo) {
    if (convo == null || !convo.isStory || convo.characterId == null) {
      return null;
    }
    final cards = ref.watch(characterCardsProvider).value;
    if (cards == null) return null;
    for (final c in cards) {
      if (c.id == convo.characterId) return c.name;
    }
    return null;
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

  void _openPlot(Conversation convo, {required bool canPinTools}) {
    if (canPinTools) {
      setState(() => _toolsOpen = true);
      return;
    }
    showStoryPanel(context, convo);
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(chatControllerProvider);
    final controller = ref.read(chatControllerProvider.notifier);
    final current = asyncState.value?.current;

    // Auto-scroll as content streams in (only while stuck to the bottom).
    // Switching conversations resumes following and snaps to the latest turn.
    ref.listen(chatControllerProvider, (prev, next) {
      if (prev?.value?.currentId != next.value?.currentId) {
        _stick = true;
        _messageKeys.clear();
        if (_selecting) {
          _selecting = false;
          _selectedIds.clear();
        }
      }
      _scrollToBottom();
    });

    // History search “定位” → scroll to a specific message once the list
    // has built GlobalKeys for the new conversation's bubbles.
    ref.listen<String?>(pendingJumpMessageIdProvider, (prev, next) {
      final id = next;
      if (id == null || id.isEmpty) return;
      void tryJump([int attempt = 0]) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_messageKeys[id]?.currentContext != null) {
            _scrollToMessage(id);
            ref.read(pendingJumpMessageIdProvider.notifier).clear();
          } else if (attempt < 10) {
            tryJump(attempt + 1);
          } else {
            ref.read(pendingJumpMessageIdProvider.notifier).clear();
          }
        });
      }

      tryJump();
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
            final dualPane =
                constraints.maxWidth >= WorkspaceBreakpoints.dualPane;
            final triplePane =
                constraints.maxWidth >= WorkspaceBreakpoints.triplePane;
            final storyLike =
                current != null && (current.isStory || current.isEnsemble);
            final showHistory = dualPane && _historyOpen;
            final showTools = triplePane && storyLike && _toolsOpen;
            final scheme = Theme.of(context).colorScheme;
            final speakerName = _characterNameFor(current);
            final mode = current?.mode ?? ConversationMode.chat;
            final modeColor = ModeStyle.color(mode);
            final titleText = current?.isEnsemble == true
                ? (current?.title ?? '角色大乱斗')
                : current?.isStory == true
                ? (speakerName ?? current?.title ?? '故事')
                : (current?.title.isNotEmpty == true
                      ? current!.title
                      : 'Expert Chat');
            final beats = current?.outlineBeats ?? const <String>[];
            final beatProgress = current == null || !current.isStory
                ? null
                : beats.isEmpty
                ? null
                : '节拍 ${current.plotCursor.clamp(0, beats.length)}/${beats.length}';
            final settings = ref.watch(settingsControllerProvider).value;
            final contextEnabled = settings?.context.enabled ?? false;
            final contextReport = current == null
                ? null
                : asyncState.value?.contextReports[current.id];
            final contextInputBudget =
                settings?.context.inputBudgetTokens ?? 0;
            return Scaffold(
              appBar: AppBar(
                titleSpacing: dualPane ? 20 : 8,
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: modeColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(
                          color: modeColor.withValues(alpha: 0.28),
                        ),
                      ),
                      child: Icon(
                        ModeStyle.icon(mode, outlined: false),
                        size: 17,
                        color: modeColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(titleText, overflow: TextOverflow.ellipsis),
                          if (current != null && storyLike)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _ModePill(
                                    label: current.localCast.isNotEmpty
                                        ? '导演故事'
                                        : ModeStyle.label(mode),
                                    color: modeColor,
                                    icon: ModeStyle.icon(mode),
                                  ),
                                  if (beatProgress != null) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      beatProgress,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                  if (storyLike) ...[
                                    const SizedBox(width: 6),
                                    GestureDetector(
                                      onTap: () => _openPlot(
                                        current,
                                        canPinTools: triplePane,
                                      ),
                                      child: Text(
                                        '情节',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              color: modeColor,
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(1),
                  child: Container(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.85),
                  ),
                ),
                actions: [
                  if (contextEnabled)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Center(
                        child: _ContextUsageChip(
                          report: contextReport,
                          inputBudget: contextInputBudget,
                        ),
                      ),
                    ),
                  if (dualPane)
                    IconButton(
                      tooltip: _historyOpen ? '隐藏会话列表' : '显示会话列表',
                      icon: Icon(
                        _historyOpen
                            ? Icons.view_sidebar_outlined
                            : Icons.view_sidebar,
                      ),
                      onPressed: () =>
                          setState(() => _historyOpen = !_historyOpen),
                    ),
                  if (triplePane && storyLike)
                    IconButton(
                      tooltip: _toolsOpen ? '隐藏情节面板' : '显示情节面板',
                      icon: Icon(
                        _toolsOpen
                            ? Icons.vertical_split
                            : Icons.vertical_split_outlined,
                      ),
                      onPressed: () => setState(() => _toolsOpen = !_toolsOpen),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '新建',
                    icon: const Icon(Icons.add_comment_outlined),
                    onSelected: (v) {
                      if (v == 'chat') {
                        controller.newConversation();
                      } else if (v == 'story') {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DirectorStorySetupPage(),
                          ),
                        );
                      } else if (v == 'ensemble') {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const EnsembleSetupPage(),
                          ),
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'chat',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            ModeStyle.icon(ConversationMode.chat),
                            color: ModeStyle.chat,
                          ),
                          title: Text(
                            ModeStyle.longLabel(ConversationMode.chat),
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'story',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            ModeStyle.icon(ConversationMode.story),
                            color: ModeStyle.story,
                          ),
                          title: Text('导演故事'),
                          subtitle: const Text('输入情节，AI 自动选角并编排'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'ensemble',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            ModeStyle.icon(ConversationMode.ensemble),
                            color: ModeStyle.ensemble,
                          ),
                          title: Text(
                            ModeStyle.longLabel(ConversationMode.ensemble),
                          ),
                          subtitle: const Text('多角色同台对谈'),
                        ),
                      ),
                    ],
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (v) {
                      if (v == 'export') _export(current);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'export',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.ios_share_outlined),
                          title: Text('导出 Markdown'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              drawer: dualPane ? null : _HistoryDrawer(asyncState: asyncState),
              body: Row(
                children: [
                  if (showHistory) ...[
                    SizedBox(
                      width: _historyWidth,
                      child: _HistoryPanel(asyncState: asyncState),
                    ),
                    _PaneResizeHandle(
                      onDrag: (dx) {
                        setState(() {
                          _historyWidth = (_historyWidth + dx).clamp(
                            WorkspacePaneDefaults.historyMin,
                            WorkspacePaneDefaults.historyMax,
                          );
                        });
                      },
                    ),
                  ],
                  Expanded(
                    child: asyncState.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(child: Text('出错了：$e')),
                      data: (state) => _chatColumn(
                        state,
                        controller,
                        canPinTools: triplePane,
                      ),
                    ),
                  ),
                  if (showTools) ...[
                    _PaneResizeHandle(
                      onDrag: (dx) {
                        setState(() {
                          _toolsWidth = (_toolsWidth - dx).clamp(
                            WorkspacePaneDefaults.toolsMin,
                            WorkspacePaneDefaults.toolsMax,
                          );
                        });
                      },
                    ),
                    SizedBox(
                      width: _toolsWidth,
                      child: StoryPanelBody(
                        key: ValueKey('tools-${current.id}'),
                        conversationId: current.id,
                        embedded: true,
                        onClose: () => setState(() => _toolsOpen = false),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _chatColumn(
    ChatState state,
    ChatController controller, {
    required bool canPinTools,
  }) {
    final convo = state.current;
    final messages = convo?.activePath ?? const <ChatMessage>[];
    // Whether the in-flight generation (if any) belongs to THIS conversation;
    // another conversation's stream must not light up bubbles here.
    final streamingHere = convo != null && state.streamingConvoId == convo.id;
    final speakerName = _characterNameFor(convo);
    final needsSetup = state.error != null && state.error!.contains('API Key');
    final settings = ref.watch(settingsControllerProvider).value;
    final ui = settings?.ui ?? const UiPrefs();
    final contentMax = ui.contentWidth.maxWidth;
    final densityPad = ui.density == DensityPref.compact
        ? const EdgeInsets.fromLTRB(16, 12, 16, 20)
        : const EdgeInsets.fromLTRB(24, 18, 24, 28);
    return Column(
      children: [
        if (state.error != null)
          _ErrorBanner(
            message: state.error!,
            onRetry:
                state.isStreaming ||
                    (convo != null &&
                        convo.activePath.isNotEmpty &&
                        convo.activePath.last.kind ==
                            MessageKind.generatedImage)
                ? null
                : () => controller.retryLast(),
            onOpenSettings: needsSetup ? () => openShellTab(ref, 2) : null,
          ),
        if (convo != null && convo.isStory)
          _StorySessionBar(
            conversation: convo,
            characterName: convo.localCast.isNotEmpty
                ? '导演模式 · ${convo.localCast.length} 位角色'
                : speakerName,
            onOpenPlot: () => _openPlot(convo, canPinTools: canPinTools),
            onAdvance: state.isStreaming ? null : controller.advancePlot,
            onNudgeBack: () => controller.adjustPlotCursor(-1),
            onNudgeForward: () => controller.adjustPlotCursor(1),
          ),
        if (convo != null && convo.isEnsemble)
          _EnsembleSessionBar(
            conversation: convo,
            busy: state.isStreaming,
            onNext: state.isStreaming ? null : controller.ensembleNextTurn,
            onAuto: state.isStreaming
                ? null
                : () => controller.ensembleAutoPlay(rounds: 6),
            onOpenPlot: () => _openPlot(convo, canPinTools: canPinTools),
          ),
        Expanded(
          child: messages.isEmpty
              ? const _EmptyState()
              : Stack(
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: contentMax),
                        child: ListView.builder(
                          controller: _scroll,
                          padding: densityPad,
                          itemCount: messages.length,
                          itemBuilder: (context, i) {
                            final m = messages[i];
                            final isLast = i == messages.length - 1;
                            final isLastAssistant =
                                isLast && m.role == MessageRole.assistant;
                            final (bIdx, bCount) = convo!.branchInfo(m.id);
                            return KeyedSubtree(
                              key: _keyForMessage(m.id),
                              child: MessageBubble(
                                // Keyed by message id: bubbles hold local edit
                                // state that must not leak across messages when
                                // the list shifts (branch switch, new turns).
                                key: ValueKey(m.id),
                                message: m,
                                isStreaming: streamingHere && isLastAssistant,
                                speakerName: m.role == MessageRole.assistant
                                    ? (m.speakerName ?? speakerName)
                                    : null,
                                userLabel: convo.localCast.isNotEmpty
                                    ? '导演'
                                    : null,
                                onRegenerate:
                                    (isLastAssistant &&
                                        !state.isStreaming &&
                                        !_selecting &&
                                        m.kind != MessageKind.generatedImage)
                                    ? controller.regenerate
                                    : null,
                                onEdit:
                                    (m.role == MessageRole.user &&
                                        !state.isStreaming &&
                                        !_selecting)
                                    ? (text) =>
                                          controller.editMessage(m.id, text)
                                    : null,
                                branchIndex: bIdx,
                                branchCount: bCount,
                                onPrevBranch: () =>
                                    controller.switchBranch(m.id, -1),
                                onNextBranch: () =>
                                    controller.switchBranch(m.id, 1),
                                messageStyle: ui.messageStyle,
                                liveMarkdown: ui.liveMarkdown,
                                selectionMode: _selecting,
                                selected: _selectedIds.contains(m.id),
                                onToggleSelect: () => _toggleSelect(m.id),
                                onStartSelect: () => _enterSelect(m.id),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    // Shown only when the user has scrolled away from the
                    // bottom; tapping resumes follow + snaps to the latest.
                    if (!_stick && !_selecting)
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
        if (_selecting)
          _SelectionShareBar(
            count: _selectedIds.length,
            onCancel: _exitSelect,
            onCopy: () => _copySelectedMarkdown(messages, convo),
            onShare: () => _shareSelected(messages, convo),
          ),
        if (!_selecting)
        _Composer(
          controller: _input,
          isStreaming: state.isStreaming,
          deepThink: state.deepThink,
          searchMode: state.searchMode,
          isSearching: state.isSearching,
          attachments: _attachments,
          picking: _picking,
          storyLike: convo != null && (convo.isStory || convo.isEnsemble),
          directorMode: convo?.localCast.isNotEmpty ?? false,
          visionConfigured: settings?.visionConfigured ?? false,
          imageGenerationConfigured:
              settings?.imageGenerationConfigured ?? false,
          imageMode:
              _imageMode && (settings?.imageGenerationConfigured ?? false),
          onToggleDeepThink: controller.toggleDeepThink,
          onToggleSearch: controller.toggleSearch,
          onToggleImageMode: _toggleImageMode,
          onPickDocuments: _pickDocuments,
          onPickImages: _pickImages,
          onRemoveAttachment: _removeAttachment,
          onSend: _send,
          onStop: controller.stop,
        ),
      ],
    );
  }
}

/// Compact bar shown only while multi-selecting messages — keeps the composer
/// uncluttered the rest of the time.
class _SelectionShareBar extends StatelessWidget {
  const _SelectionShareBar({
    required this.count,
    required this.onCancel,
    required this.onCopy,
    required this.onShare,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Text(
                '已选 $count',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton(onPressed: onCancel, child: const Text('取消')),
              const SizedBox(width: 4),
              OutlinedButton.icon(
                onPressed: count == 0 ? null : onCopy,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('复制 MD'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: count == 0 ? null : onShare,
                icon: const Icon(Icons.ios_share_outlined, size: 18),
                label: const Text('分享'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.isStreaming,
    required this.deepThink,
    required this.searchMode,
    required this.isSearching,
    required this.attachments,
    required this.picking,
    required this.storyLike,
    required this.directorMode,
    required this.visionConfigured,
    required this.imageGenerationConfigured,
    required this.imageMode,
    required this.onToggleDeepThink,
    required this.onToggleSearch,
    required this.onToggleImageMode,
    required this.onPickDocuments,
    required this.onPickImages,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool isStreaming;
  final bool deepThink;
  final SearchMode searchMode;
  final bool isSearching;
  final List<Attachment> attachments;
  final bool picking;
  final bool storyLike;
  final bool directorMode;
  final bool visionConfigured;
  final bool imageGenerationConfigured;
  final bool imageMode;
  final VoidCallback onToggleDeepThink;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleImageMode;
  final VoidCallback onPickDocuments;
  final VoidCallback onPickImages;
  final ValueChanged<String> onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  /// DeepSeek-style expandable “+” tray for upload / image actions.
  bool _plusOpen = false;

  void _togglePlus() {
    if (widget.isStreaming) return;
    setState(() => _plusOpen = !_plusOpen);
  }

  void _closePlus() {
    if (_plusOpen) setState(() => _plusOpen = false);
  }

  void _runAndClose(VoidCallback action) {
    _closePlus();
    action();
  }

  @override
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Collapse the tray while a turn is in flight so it doesn't sit open over
    // the stop button / streaming UI.
    if (widget.isStreaming && _plusOpen) {
      _plusOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compactHeight = MediaQuery.sizeOf(context).height < 720;
    final hint = widget.imageMode
        ? '描述你想生成的图片…'
        : widget.directorMode
        ? '输入导演指令，或点击“继续下一节”…'
        : widget.storyLike
        ? '续写反应，或输入旁白…'
        : '写下你的想法…';
    final canAttach = !widget.isStreaming && !widget.picking && !widget.imageMode;
    return Container(
      key: const ValueKey('chat-composer'),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.9)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 6, 12, compactHeight ? 7 : 9),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Model-capability chips stay on the top strip; media actions
                  // live in the expandable “+” tray (DeepSeek-style).
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _ComposerToggleChip(
                          selected: widget.deepThink,
                          icon: Icons.psychology_outlined,
                          label: '深度思考',
                          tooltip: '开启后本次对话使用深度推理模型',
                          onSelected: widget.onToggleDeepThink,
                        ),
                        const SizedBox(width: 6),
                        _ComposerToggleChip(
                          selected: widget.searchMode != SearchMode.off,
                          icon: Icons.travel_explore,
                          label: widget.searchMode.composerLabel,
                          tooltip:
                              '点击切换：关闭 → 自动（模型按需搜索）→ 强制（先搜索再回答）；'
                              '搜索服务可在「设置」配置',
                          onSelected: widget.onToggleSearch,
                        ),
                        if (widget.imageMode) ...[
                          const SizedBox(width: 6),
                          _ComposerToggleChip(
                            selected: true,
                            icon: Icons.auto_awesome,
                            label: '生图中',
                            tooltip: '再次点击可退出生图模式',
                            onSelected: widget.onToggleImageMode,
                          ),
                        ],
                        if (widget.isSearching) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer.withValues(
                                alpha: 0.55,
                              ),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
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
                                    color: scheme.onPrimaryContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _plusOpen
                        ? Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: _ComposerPlusTray(
                              visionConfigured: widget.visionConfigured,
                              imageGenerationConfigured:
                                  widget.imageGenerationConfigured,
                              imageMode: widget.imageMode,
                              enabled: canAttach || widget.imageMode,
                              picking: widget.picking,
                              onPickDocuments: canAttach
                                  ? () => _runAndClose(widget.onPickDocuments)
                                  : null,
                              onPickImages:
                                  canAttach && widget.visionConfigured
                                  ? () => _runAndClose(widget.onPickImages)
                                  : null,
                              onToggleImageMode: widget.isStreaming
                                  ? null
                                  : () => _runAndClose(
                                      widget.onToggleImageMode,
                                    ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.95),
                      ),
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
                        if (widget.attachments.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                            child: SingleChildScrollView(
                              key: const ValueKey('composer-attachment-strip'),
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (
                                    var i = 0;
                                    i < widget.attachments.length;
                                    i++
                                  )
                                    Padding(
                                      padding: EdgeInsets.only(
                                        right:
                                            i == widget.attachments.length - 1
                                            ? 0
                                            : 6,
                                      ),
                                      child: AttachmentChip(
                                        attachment: widget.attachments[i],
                                        onRemove: () =>
                                            widget.onRemoveAttachment(
                                              widget.attachments[i].id,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _ComposerPlusButton(
                              open: _plusOpen,
                              enabled: !widget.isStreaming,
                              picking: widget.picking,
                              onPressed: _togglePlus,
                            ),
                            Expanded(
                              child: CallbackShortcuts(
                                bindings: {
                                  const SingleActivator(
                                    LogicalKeyboardKey.enter,
                                  ): () {
                                    if (!widget.isStreaming &&
                                        !widget
                                            .controller
                                            .value
                                            .composing
                                            .isValid) {
                                      onSendViaWidget();
                                    }
                                  },
                                },
                                child: TextField(
                                  controller: widget.controller,
                                  minLines: 1,
                                  maxLines: compactHeight ? 3 : 5,
                                  textInputAction: TextInputAction.newline,
                                  onTap: _closePlus,
                                  decoration: InputDecoration(
                                    hintText: hint,
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 7,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            widget.isStreaming
                                ? IconButton.filled(
                                    onPressed: widget.onStop,
                                    icon: const Icon(Icons.stop_rounded),
                                    tooltip: '停止',
                                    style: IconButton.styleFrom(
                                      fixedSize: const Size.square(40),
                                      backgroundColor: scheme.errorContainer,
                                      foregroundColor: scheme.onErrorContainer,
                                    ),
                                  )
                                : IconButton.filled(
                                    onPressed: () {
                                      _closePlus();
                                      widget.onSend();
                                    },
                                    icon: const Icon(
                                      Icons.arrow_upward_rounded,
                                    ),
                                    tooltip: '发送',
                                    style: IconButton.styleFrom(
                                      fixedSize: const Size.square(40),
                                      backgroundColor: scheme.primary,
                                      foregroundColor: scheme.onPrimary,
                                    ),
                                  ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void onSendViaWidget() {
    _closePlus();
    widget.onSend();
  }
}

/// Circular “+” control that expands the media tray (DeepSeek-style).
class _ComposerPlusButton extends StatelessWidget {
  const _ComposerPlusButton({
    required this.open,
    required this.enabled,
    required this.picking,
    required this.onPressed,
  });

  final bool open;
  final bool enabled;
  final bool picking;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = open;
    return Semantics(
      key: const ValueKey('composer-plus-button'),
      button: true,
      enabled: enabled,
      label: open ? '收起附件菜单' : '展开附件菜单',
      excludeSemantics: true,
      child: Tooltip(
        message: open ? '收起' : '上传文件、图片等',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2, right: 2),
          child: Material(
            color: active
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: picking
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        )
                      : AnimatedRotation(
                          turns: open ? 0.125 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            Icons.add_rounded,
                            size: 22,
                            color: enabled
                                ? (active
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurfaceVariant)
                                : scheme.onSurface.withValues(alpha: 0.38),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Expandable action tray revealed by the composer “+” button.
class _ComposerPlusTray extends StatelessWidget {
  const _ComposerPlusTray({
    required this.visionConfigured,
    required this.imageGenerationConfigured,
    required this.imageMode,
    required this.enabled,
    required this.picking,
    required this.onPickDocuments,
    required this.onPickImages,
    required this.onToggleImageMode,
  });

  final bool visionConfigured;
  final bool imageGenerationConfigured;
  final bool imageMode;
  final bool enabled;
  final bool picking;
  final VoidCallback? onPickDocuments;
  final VoidCallback? onPickImages;
  final VoidCallback? onToggleImageMode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('composer-plus-tray'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.85),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ComposerPlusAction(
              icon: Icons.folder_open_outlined,
              label: '上传文件',
              tooltip: '上传 PDF / Office / 文本等（最多 5 个，单个最大 10 MB）',
              enabled: onPickDocuments != null && !picking,
              onTap: onPickDocuments,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ComposerPlusAction(
              icon: Icons.image_outlined,
              label: '上传图片',
              tooltip: visionConfigured
                  ? '上传图片供视觉模型分析（最多 5 个，单个最大 10 MB）'
                  : '请先在设置中配置视觉 API',
              enabled: onPickImages != null && !picking,
              onTap: onPickImages,
            ),
          ),
          if (imageGenerationConfigured) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _ComposerPlusAction(
                icon: imageMode
                    ? Icons.auto_awesome
                    : Icons.auto_awesome_outlined,
                label: imageMode ? '退出生图' : '图片生成',
                tooltip: imageMode
                    ? '退出生图模式，回到普通对话'
                    : '使用独立配置的图片生成 API',
                selected: imageMode,
                enabled: onToggleImageMode != null,
                onTap: onToggleImageMode,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ComposerPlusAction extends StatelessWidget {
  const _ComposerPlusAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool enabled;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : selected
        ? scheme.primary
        : scheme.onSurface;
    final bg = selected
        ? scheme.primaryContainer.withValues(alpha: 0.7)
        : scheme.surface;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '$label，$tooltip',
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.primary.withValues(alpha: 0.14)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, size: 22, color: fg),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextUsageChip extends StatelessWidget {
  const _ContextUsageChip({required this.report, required this.inputBudget});

  final ContextWindowReport? report;
  final int inputBudget;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = report?.sentTokens ?? 0;
    final budget = report?.inputBudgetTokens ?? inputBudget;
    final fraction = budget <= 0 ? 0.0 : (current / budget).clamp(0.0, 1.0);
    final managed = report?.managed ?? false;
    final color = fraction >= 0.9
        ? scheme.error
        : fraction >= 0.7
        ? scheme.tertiary
        : scheme.primary;
    final detail = report == null
        ? '上下文预算 ${_compactTokens(budget)}'
        : '上下文约 ${_compactTokens(current)} / ${_compactTokens(budget)}'
              '${managed ? ' · 已自动压缩' : ''}';
    final label = report == null
        ? _compactTokens(budget)
        : '${_compactTokens(current)} / ${_compactTokens(budget)}'
              '${managed ? ' · 已压缩' : ''}';
    return Semantics(
      key: const ValueKey('chat-context-usage'),
      label: detail,
      value: '${(fraction * 100).round()}%',
      excludeSemantics: true,
      child: Tooltip(
        message: detail,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: managed
                ? color.withValues(alpha: 0.12)
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  semanticsLabel: detail,
                  semanticsValue: '${(fraction * 100).round()}%',
                  value: fraction,
                  strokeWidth: 2,
                  color: color,
                  backgroundColor: scheme.outlineVariant,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: managed ? color : scheme.onSurfaceVariant,
                  fontWeight: managed ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _compactTokens(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(value % 1000 == 0 ? 0 : 1)}K';
    }
    return '$value';
  }
}

class _ComposerToggleChip extends StatelessWidget {
  const _ComposerToggleChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onSelected,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      toggled: selected,
      label: '$label，$tooltip',
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: selected
              ? scheme.primaryContainer.withValues(alpha: 0.75)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onSelected,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: fg),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
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

  /// null = all modes.
  ConversationMode? _modeFilter;
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
    if (_modeFilter != null && c.mode != _modeFilter) return false;
    if (q.isEmpty) return true;
    final lower = q.toLowerCase();
    if (c.title.toLowerCase().contains(lower)) return true;
    return c.messages.any((m) => m.content.toLowerCase().contains(lower));
  }

  /// Best content hit for search preview + jump target.
  ({String? messageId, String snippet}) _searchHit(Conversation c, String q) {
    if (q.isEmpty) return (messageId: null, snippet: '');
    final lower = q.toLowerCase();
    // Prefer active-path messages so jump lands on something visible.
    for (final m in c.activePath) {
      final idx = m.content.toLowerCase().indexOf(lower);
      if (idx < 0) continue;
      return (messageId: m.id, snippet: _snippetAround(m.content, idx, q.length));
    }
    for (final m in c.messages) {
      final idx = m.content.toLowerCase().indexOf(lower);
      if (idx < 0) continue;
      return (messageId: m.id, snippet: _snippetAround(m.content, idx, q.length));
    }
    return (messageId: null, snippet: '');
  }

  String _snippetAround(String content, int index, int queryLen) {
    final from = (index - 16).clamp(0, content.length);
    final to = (index + queryLen + 36).clamp(0, content.length);
    var snip = content
        .substring(from, to)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (from > 0) snip = '…$snip';
    if (to < content.length) snip = '$snip…';
    return snip;
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

    // Header is a solid, non-scrolling block so list items never paint under
    // the controls. The equal-width segmented filter stays on one clean row.
    final header = Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.98),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '会话',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '新建普通对话',
                  onPressed: () {
                    controller.newConversation();
                    _closeDrawerIfAny();
                  },
                  icon: Icon(Icons.add, color: scheme.primary),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _ModeFilterBar(
              selected: _modeFilter,
              onSelected: (mode) => setState(() => _modeFilter = mode),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: TextField(
              key: const ValueKey('conversation-search-field'),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索标题或正文，点结果可定位…',
                filled: true,
                fillColor: scheme.surfaceContainer,
              ),
              onChanged: _scheduleSearch,
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
            header,
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Text(
                        '没有匹配的会话',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final c = visible[index];
                        final modeColor = ModeStyle.color(c.mode);
                        if (c.id == _renamingId) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              tileColor: scheme.surfaceContainer,
                              leading: Icon(
                                ModeStyle.icon(c.mode),
                                color: modeColor,
                              ),
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
                        final selected = c.id == state?.currentId;
                        final ({String? messageId, String snippet}) hit =
                            _query.isEmpty
                            ? (messageId: null, snippet: '')
                            : _searchHit(c, _query);
                        final preview = hit.snippet.isNotEmpty
                            ? hit.snippet
                            : _conversationPreview(c);
                        final timeLabel = _relativeTime(c.updatedAt);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Material(
                            color: selected
                                ? scheme.primaryContainer.withValues(
                                    alpha: 0.45,
                                  )
                                : scheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                controller.selectConversation(c.id);
                                if (hit.messageId != null) {
                                  ref
                                      .read(
                                        pendingJumpMessageIdProvider.notifier,
                                      )
                                      .set(hit.messageId);
                                }
                                _closeDrawerIfAny();
                              },
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  10,
                                  4,
                                  10,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: modeColor.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                      child: Icon(
                                        ModeStyle.icon(c.mode),
                                        size: 18,
                                        color: modeColor,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            c.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          if (preview.isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              hit.snippet.isNotEmpty
                                                  ? '匹配：$preview'
                                                  : preview,
                                              maxLines: hit.snippet.isNotEmpty
                                                  ? 2
                                                  : 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color: hit.snippet.isNotEmpty
                                                        ? scheme.primary
                                                        : scheme
                                                              .onSurfaceVariant,
                                                    fontWeight:
                                                        hit.snippet.isNotEmpty
                                                        ? FontWeight.w600
                                                        : null,
                                                  ),
                                            ),
                                          ],
                                          const SizedBox(height: 4),
                                          Text(
                                            [
                                              c.localCast.isNotEmpty
                                                  ? '导演故事'
                                                  : ModeStyle.label(c.mode),
                                              if (hit.messageId != null) '可定位',
                                            ].join(' · '),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: modeColor,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          timeLabel,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                        PopupMenuButton<String>(
                                          icon: const Icon(
                                            Icons.more_horiz,
                                            size: 20,
                                          ),
                                          padding: EdgeInsets.zero,
                                          onSelected: (v) {
                                            if (v == 'rename') {
                                              _startRename(c);
                                            }
                                            if (v == 'delete') {
                                              _confirmDelete(c);
                                            }
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
                                                style: TextStyle(
                                                  color: scheme.error,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
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

String _conversationPreview(Conversation c) {
  final path = c.activePath;
  for (var i = path.length - 1; i >= 0; i--) {
    final text = path[i].content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isNotEmpty) {
      return text.length > 48 ? '${text.substring(0, 48)}…' : text;
    }
  }
  return '';
}

String _relativeTime(DateTime when) {
  final now = DateTime.now();
  final diff = now.difference(when);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟';
  if (diff.inHours < 24) return '${diff.inHours} 小时';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final y = when.year.toString().padLeft(4, '0');
  final m = when.month.toString().padLeft(2, '0');
  final d = when.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

class _ModeFilterBar extends StatelessWidget {
  const _ModeFilterBar({required this.selected, required this.onSelected});

  final ConversationMode? selected;
  final ValueChanged<ConversationMode?> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options =
        <({String id, String label, IconData icon, ConversationMode? mode})>[
          (id: 'all', label: '全部', icon: Icons.apps_rounded, mode: null),
          for (final mode in ConversationMode.values)
            (
              id: mode.name,
              label: ModeStyle.label(mode),
              icon: ModeStyle.icon(mode),
              mode: mode,
            ),
        ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcons =
            constraints.maxWidth >= 264 &&
            MediaQuery.textScalerOf(context).scale(12) <= 14.4;
        return Container(
          key: const ValueKey('conversation-mode-filter'),
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
          child: Row(
            children: [
              for (var index = 0; index < options.length; index++) ...[
                if (index > 0) const SizedBox(width: 2),
                Expanded(
                  child: _ModeFilterSegment(
                    key: ValueKey(
                      'conversation-mode-filter-${options[index].id}',
                    ),
                    label: options[index].label,
                    icon: showIcons ? options[index].icon : null,
                    selected: selected == options[index].mode,
                    onTap: () => onSelected(options[index].mode),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ModeFilterSegment extends StatelessWidget {
  const _ModeFilterSegment({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected ? scheme.primary : scheme.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label会话筛选',
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.10),
                    scheme.surface,
                  )
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.24)
                  : Colors.transparent,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.08),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: onTap,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: 5),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ensemble controls: next speaker / auto-play / venue.
class _EnsembleSessionBar extends StatelessWidget {
  const _EnsembleSessionBar({
    required this.conversation,
    required this.busy,
    required this.onNext,
    required this.onAuto,
    required this.onOpenPlot,
  });

  final Conversation conversation;
  final bool busy;
  final VoidCallback? onNext;
  final VoidCallback? onAuto;
  final VoidCallback onOpenPlot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = ModeStyle.ensemble;
    final cast = conversation.castIds;
    final idx = cast.isEmpty
        ? 0
        : conversation.nextSpeakerIndex.clamp(0, cast.length - 1);
    final venue = conversation.venue.trim().isEmpty
        ? '未设场地'
        : conversation.venue.trim();

    return Material(
      color: Color.lerp(scheme.surface, accent, 0.08),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.85),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              ModeStyle.icon(ConversationMode.ensemble),
              size: 18,
              color: accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: onOpenPlot,
                borderRadius: BorderRadius.circular(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '下一位 · #${idx + 1} / ${cast.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      venue,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _SessionMiniButton(
              label: busy ? '发言中' : '下一角色',
              filled: true,
              color: accent,
              onPressed: onNext,
            ),
            const SizedBox(width: 6),
            _SessionMiniButton(label: '自动 ×6', onPressed: onAuto),
          ],
        ),
      ),
    );
  }
}

/// Always-visible story controls: current beat + plot settings + advance.
class _StorySessionBar extends StatelessWidget {
  const _StorySessionBar({
    required this.conversation,
    required this.characterName,
    required this.onOpenPlot,
    required this.onAdvance,
    required this.onNudgeBack,
    required this.onNudgeForward,
  });

  final Conversation conversation;
  final String? characterName;
  final VoidCallback onOpenPlot;
  final VoidCallback? onAdvance;
  final VoidCallback onNudgeBack;
  final VoidCallback onNudgeForward;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = ModeStyle.story;
    final beats = conversation.outlineBeats;
    final cursor = conversation.plotCursor;
    final progress = beats.isEmpty
        ? '无大纲'
        : '${cursor.clamp(0, beats.length)}/${beats.length}';
    final beatText = beats.isEmpty
        ? (conversation.authorNote.trim().isEmpty
              ? '点「情节」写大纲与导演指令'
              : '导演指令已设置 · 可写大纲后推进')
        : cursor < beats.length
        ? '当前：${beats[cursor.clamp(0, beats.length - 1)]}'
        : '大纲已走完 · 可自由续写';
    final noteHint = conversation.authorNote.trim().isEmpty
        ? null
        : '导演指令已启用';
    final wiCount = conversation.worldInfoIds.length;

    return Material(
      color: Color.lerp(scheme.surface, accent, 0.08),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.85),
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.timeline, size: 18, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: onOpenPlot,
                borderRadius: BorderRadius.circular(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (characterName != null && characterName!.isNotEmpty)
                          characterName!,
                        '节拍 $progress',
                        if (wiCount > 0) '设定 $wiCount',
                        ?noteHint,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      beatText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '回退一拍',
              visualDensity: VisualDensity.compact,
              onPressed: onNudgeBack,
              icon: const Icon(Icons.chevron_left, size: 22),
            ),
            _SessionMiniButton(
              label: conversation.localCast.isNotEmpty ? '继续下一节' : '推进情节',
              filled: true,
              color: accent,
              onPressed: onAdvance,
            ),
            IconButton(
              tooltip: '前进一拍',
              visualDensity: VisualDensity.compact,
              onPressed: onNudgeForward,
              icon: const Icon(Icons.chevron_right, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionMiniButton extends StatelessWidget {
  const _SessionMiniButton({
    required this.label,
    required this.onPressed,
    this.filled = false,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    if (filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          minimumSize: const Size(0, 34),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.message,
    this.onRetry,
    this.onOpenSettings,
  });
  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenSettings;

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
          if (onOpenSettings != null)
            TextButton(
              onPressed: onOpenSettings,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onErrorContainer,
              ),
              child: const Text('去填写'),
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

/// Thin drag strip between workspace panes.
class _PaneResizeHandle extends StatelessWidget {
  const _PaneResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: Container(
          width: 6,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.9),
            ),
          ),
        ),
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
          color: scheme.surfaceContainer,
          elevation: 3,
          shadowColor: scheme.shadow.withValues(alpha: 0.2),
          shape: CircleBorder(
            side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.9),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Icon(
                Icons.arrow_downward_rounded,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxHeight < 300 || constraints.maxWidth < 320;
        final edge = compact ? 12.0 : 24.0;
        final minContentHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight - edge * 2)
                  .clamp(0.0, double.infinity)
                  .toDouble()
            : 0.0;
        return SingleChildScrollView(
          key: const ValueKey('chat-empty-state-scroll'),
          padding: EdgeInsets.all(edge),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minContentHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Container(
                  padding: compact
                      ? const EdgeInsets.fromLTRB(20, 18, 20, 18)
                      : const EdgeInsets.fromLTRB(28, 28, 28, 24),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(compact ? 20 : 24),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.9),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: scheme.shadow.withValues(alpha: 0.05),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: compact ? 44 : 56,
                        height: compact ? 44 : 56,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              scheme.primary,
                              Color.lerp(
                                scheme.primary,
                                scheme.secondary,
                                0.35,
                              )!,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(
                            compact ? 15 : 18,
                          ),
                        ),
                        child: Icon(
                          Icons.auto_awesome,
                          color: scheme.onPrimary,
                          size: compact ? 23 : 28,
                        ),
                      ),
                      SizedBox(height: compact ? 12 : 18),
                      Text(
                        '开始一段对话',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      SizedBox(height: compact ? 6 : 8),
                      Text(
                        '在下方输入消息；API Key 在底栏「设置」里配置。\n'
                        '也可点右上角新建：普通对话 / 角色故事 / 大乱斗。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: compact ? 1.35 : 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
