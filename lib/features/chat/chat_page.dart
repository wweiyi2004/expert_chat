import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
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
import '../../domain/clipboard/clipboard_media.dart';
import '../../domain/chat/conversation_outline.dart';
import '../../domain/export/conversation_export.dart';
import '../../domain/memory/memory_candidate_service.dart';
import '../../domain/memory/memory_entry.dart';
import '../../domain/memory/memory_safety.dart';
import '../../domain/share/shared_intake.dart';
import '../../domain/speech/text_to_speech_service.dart';
import '../../domain/story/story_length_budget.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/tools/attachment_ingestor.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import '../../state/memory_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import '../settings/model_setup_page.dart';
import '../shared/recovery_notice.dart';
import '../../domain/errors/app_failure.dart';
import '../memory/memory_candidate_review_sheet.dart';
import '../story/director_story_setup_page.dart';
import '../story/ensemble_setup_page.dart';
import '../story/story_panel.dart';
import '../study/study_session_actions.dart';
import 'jump_to_message.dart';
import 'pending_share.dart';
import 'chat_workspace_sidebar.dart';

import 'controllers/chat_speech_controller.dart';
import 'controllers/voice_conversation_controller.dart';
import 'widgets/chat_composer.dart';
import 'widgets/context_usage_chip.dart';
import 'widgets/chat_work_mode_switch.dart';
import 'widgets/conversation_outline_panel.dart';
import 'widgets/image_pick_confirm_bar.dart';
import 'widgets/attachment_picker.dart';
import 'widgets/message_bubble.dart';
import 'widgets/voice_conversation_panel.dart';

export 'chat_workspace_sidebar.dart' show ChatWorkspaceSidebar;

/// Page-chrome fields that stay stable while an assistant reply streams.
/// Message content is subscribed separately by [_ChatPageState._buildMessageList].
@immutable
class _ChatScaffoldSlice {
  const _ChatScaffoldSlice({
    required this.isLoading,
    required this.hasError,
    this.loadError,
    this.currentId,
    this.hasCurrent = false,
    this.isStreaming = false,
    this.error,
    this.errorConvoId,
    this.retryConversationId,
    this.deepThink = false,
    this.reasoningEffort = ReasoningEffort.high,
    this.searchMode = SearchMode.auto,
    this.imageGenMode = ImageGenMode.auto,
    this.title = '',
    this.mode = ConversationMode.chat,
    this.isStory = false,
    this.isEnsemble = false,
    this.isStudy = false,
    this.hasLocalCast = false,
    this.hasUserActivity = false,
    this.plotCursor = 0,
    this.outline = '',
    this.authorNote = '',
    this.venue = '',
    this.characterId,
    this.localCastLength = 0,
    this.worldInfoCount = 0,
    this.nextSpeakerIndex = 0,
    this.targetTotalChars = 0,
    this.customMcpServerIds = '',
    this.workMode = false,
    this.conversationIds = '',
  });

  factory _ChatScaffoldSlice.from(AsyncValue<ChatState> async) {
    final s = async.value;
    final current = s?.current;
    return _ChatScaffoldSlice(
      isLoading: async.isLoading && !async.hasValue,
      hasError: async.hasError && !async.hasValue,
      loadError: async.error,
      currentId: s?.currentId,
      hasCurrent: current != null,
      isStreaming: s?.isStreaming ?? false,
      error: s?.error,
      errorConvoId: s?.errorConvoId,
      retryConversationId: s?.retryOperation?.conversationId,
      deepThink: s?.deepThink ?? false,
      reasoningEffort: s?.reasoningEffort ?? ReasoningEffort.high,
      searchMode: s?.searchMode ?? SearchMode.auto,
      imageGenMode: s?.imageGenMode ?? ImageGenMode.auto,
      title: current?.title ?? '',
      mode: current?.mode ?? ConversationMode.chat,
      isStory: current?.isStory ?? false,
      isEnsemble: current?.isEnsemble ?? false,
      isStudy: current?.isStudy ?? false,
      hasLocalCast: current?.localCast.isNotEmpty ?? false,
      hasUserActivity: current?.hasUserActivity ?? false,
      plotCursor: current?.plotCursor ?? 0,
      outline: current?.outline ?? '',
      authorNote: current?.authorNote ?? '',
      venue: current?.venue ?? '',
      characterId: current?.characterId,
      localCastLength: current?.localCast.length ?? 0,
      worldInfoCount: current?.worldInfoIds.length ?? 0,
      nextSpeakerIndex: current?.nextSpeakerIndex ?? 0,
      targetTotalChars: current?.targetTotalChars ?? 0,
      customMcpServerIds: (current?.customMcpServerIds ?? const []).join(','),
      workMode: current?.workMode ?? false,
      conversationIds: [
        for (final c in s?.conversations ?? const <Conversation>[]) c.id,
      ].join(','),
    );
  }

  final bool isLoading;
  final bool hasError;
  final Object? loadError;
  final String? currentId;
  final bool hasCurrent;
  final bool isStreaming;
  final String? error;
  final String? errorConvoId;
  final String? retryConversationId;
  final bool deepThink;
  final ReasoningEffort reasoningEffort;
  final SearchMode searchMode;
  final ImageGenMode imageGenMode;
  final String title;
  final ConversationMode mode;
  final bool isStory;
  final bool isEnsemble;
  final bool isStudy;
  final bool hasLocalCast;
  final bool hasUserActivity;
  final int plotCursor;
  final String outline;
  final String authorNote;
  final String venue;
  final String? characterId;
  final int localCastLength;
  final int worldInfoCount;
  final int nextSpeakerIndex;
  final int targetTotalChars;
  final String customMcpServerIds;
  final bool workMode;
  final String conversationIds;

  @override
  bool operator ==(Object other) =>
      other is _ChatScaffoldSlice &&
      isLoading == other.isLoading &&
      hasError == other.hasError &&
      loadError == other.loadError &&
      currentId == other.currentId &&
      hasCurrent == other.hasCurrent &&
      isStreaming == other.isStreaming &&
      error == other.error &&
      errorConvoId == other.errorConvoId &&
      retryConversationId == other.retryConversationId &&
      deepThink == other.deepThink &&
      reasoningEffort == other.reasoningEffort &&
      searchMode == other.searchMode &&
      imageGenMode == other.imageGenMode &&
      title == other.title &&
      mode == other.mode &&
      isStory == other.isStory &&
      isEnsemble == other.isEnsemble &&
      isStudy == other.isStudy &&
      hasLocalCast == other.hasLocalCast &&
      hasUserActivity == other.hasUserActivity &&
      plotCursor == other.plotCursor &&
      outline == other.outline &&
      authorNote == other.authorNote &&
      venue == other.venue &&
      characterId == other.characterId &&
      localCastLength == other.localCastLength &&
      worldInfoCount == other.worldInfoCount &&
      nextSpeakerIndex == other.nextSpeakerIndex &&
      targetTotalChars == other.targetTotalChars &&
      customMcpServerIds == other.customMcpServerIds &&
      workMode == other.workMode &&
      conversationIds == other.conversationIds;

  @override
  int get hashCode => Object.hashAll([
    isLoading,
    hasError,
    loadError,
    currentId,
    hasCurrent,
    isStreaming,
    error,
    errorConvoId,
    retryConversationId,
    deepThink,
    reasoningEffort,
    searchMode,
    imageGenMode,
    title,
    mode,
    isStory,
    isEnsemble,
    isStudy,
    hasLocalCast,
    hasUserActivity,
    plotCursor,
    outline,
    authorNote,
    venue,
    characterId,
    localCastLength,
    worldInfoCount,
    nextSpeakerIndex,
    targetTotalChars,
    customMcpServerIds,
    workMode,
    conversationIds,
  ]);
}

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, this.desktopShell = false});

  /// The desktop app shell owns the unified workspace/history sidebar.
  /// Standalone and phone layouts keep the local drawer/two-pane fallback.
  final bool desktopShell;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Attachment> _attachments = [];
  late final ChatSpeechController _speech;
  late final VoiceConversationController _voice;
  bool _picking = false;
  int _composerEpoch = 0;

  bool _isComposerCurrent(int epoch) => mounted && epoch == _composerEpoch;
  bool _imageMode = false;
  bool _longTaskMode = false;

  /// After system image pick: confirm strip (scroll + checkbox) before attach.
  List<PendingImagePick>? _pendingImagePicks;
  bool _pendingImageForGen = false;
  int _pendingImageMaxSlots = 1;
  bool _extractingMemoryCandidates = false;
  CancelToken? _memoryCandidateCancelToken;

  /// Wide-layout tools pane (story / ensemble plot). Ignored on phone.
  bool _toolsOpen = true;

  /// Wide-layout conversation outline pane.
  bool _outlineOpen = false;
  double _outlineWidth = 280;

  /// Wide-layout history pane toggle (desktop).
  bool _historyOpen = true;
  double _historyWidth = WorkspacePaneDefaults.historyWidth;
  double _toolsWidth = WorkspacePaneDefaults.toolsWidth;

  // Keep an accidental multi-select from consuming the device's memory,
  // context window, or API request budget. The parser additionally enforces
  // format-specific limits before it extracts content.
  static const int _maxAttachments = AttachmentIngestor.maxAttachments;

  int get _imageRefCap =>
      ref
          .read(settingsControllerProvider)
          .value
          ?.imageGenerationApi
          .maxImageEditReferences ??
      1;

  int _slotCap({required bool forImageGeneration, required bool imagesOnly}) {
    if (forImageGeneration && imagesOnly) return _imageRefCap;
    return _maxAttachments;
  }

  /// Whether the view should keep following new content (stick-to-bottom). Set
  /// false the moment the user scrolls up, so streaming output no longer yanks
  /// them back down; restored when they scroll back to the bottom (or tap the
  /// jump button / send a message).
  bool _stick = true;

  /// Last streaming thinking panel expand state, for stream UI attention.
  bool _thinkingExpanded = true;

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
    WidgetsBinding.instance.addObserver(this);
    _speech = ChatSpeechController(
      input: _input,
      systemSpeechInput: ref.read(speechInputServiceProvider),
      textToSpeech: ref.read(textToSpeechServiceProvider),
      getMimoService: () => ref.read(mimoSpeechInputServiceProvider),
      getCloudConfig: () {
        final settings = ref.read(settingsControllerProvider).value;
        return settings != null && settings.asrConfigured
            ? CloudSpeechConfig(
                config: settings.asrApi,
                apiKey: settings.asrApiKey,
              )
            : null;
      },
      onNotice: _showSpeechNotice,
    )..addListener(_onSpeechChanged);
    _voice = VoiceConversationController(
      speechInput: ref.read(speechInputServiceProvider),
      textToSpeech: ref.read(textToSpeechServiceProvider),
      send: _sendVoiceTurn,
      stopReply: () => ref.read(chatControllerProvider.notifier).stopAndWait(),
      readReply: _currentVoiceReply,
      speechRequest: (messageId) => _speechRequestFor(
        messageId: messageId,
        text: '',
        settings: ref.read(settingsControllerProvider).value,
      ),
      onNotice: _showSpeechNotice,
    )..addListener(_onSpeechChanged);
    _scroll.addListener(_onScroll);
    // A share may already be pending if it arrived before this page built.
    if (ref.read(pendingSharedPayloadProvider) != null) {
      _scheduleSharedPayload();
    }
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

  Future<void> _shareSelected(
    List<ChatMessage> path,
    Conversation? convo,
  ) async {
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
          '${dir.path}${Platform.pathSeparator}expert-chat-share-${DateTime.now().millisecondsSinceEpoch}.md',
        );
        await file.writeAsString(md, encoding: utf8);
        try {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(file.path, mimeType: 'text/markdown')],
              subject: convo?.title ?? 'Expert Chat',
            ),
          );
        } finally {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      } else {
        await SharePlus.instance.share(
          ShareParams(text: md, subject: convo?.title ?? 'Expert Chat'),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分享失败：$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _copySelectedMarkdown(
    List<ChatMessage> path,
    Conversation? convo,
  ) async {
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
    _memoryCandidateCancelToken?.cancel('ChatPage disposed');
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_onSpeechChanged);
    _voice.dispose();
    _speech.removeListener(_onSpeechChanged);
    _speech.dispose();
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _voice.handleLifecycle(state);
    _speech.handleLifecycle(state);
  }

  /// Re-evaluate stick-to-bottom whenever the user scrolls. Programmatic
  /// auto-scrolls also fire this, which simply keeps [_stick] true at the bottom.
  void _onScroll() {
    if (!_scroll.hasClients || _programmaticScroll) return;
    final pos = _scroll.position;
    final atBottom = pos.maxScrollExtent - pos.pixels <= _stickThreshold;
    if (atBottom != _stick) {
      setState(() => _stick = atBottom);
      _reportStreamView();
    }
  }

  /// Resume following and snap to the latest content (jump button / send).
  void _jumpToBottom() {
    setState(() => _stick = true);
    _reportStreamView();
    _scrollToBottom(animated: true);
  }

  void _reportStreamView() {
    ref
        .read(chatControllerProvider.notifier)
        .reportStreamView(
          followingTail: _stick,
          thinkingExpanded: _thinkingExpanded,
        );
  }

  void _jumpToOutline(String messageId) {
    if (_messageKeys[messageId]?.currentContext != null) {
      _scrollToMessage(messageId);
      return;
    }
    ref.read(pendingJumpMessageIdProvider.notifier).set(messageId);
  }

  void _toggleOutline({required bool wide}) {
    if (wide) {
      setState(() {
        _outlineOpen = !_outlineOpen;
        if (_outlineOpen) _toolsOpen = false;
      });
      return;
    }
    final path =
        ref.read(chatControllerProvider).value?.current?.activePath ??
        const <ChatMessage>[];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.72,
        child: ConversationOutlinePanel(
          entries: buildConversationOutline(path),
          asSheet: true,
          onJump: (id) {
            Navigator.of(ctx).pop();
            _jumpToOutline(id);
          },
        ),
      ),
    );
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

  Future<void> _toggleTextToSpeech(
    ChatMessage message,
    SettingsState? settings,
  ) => _speech.togglePlayback(
    _speechRequestFor(
      messageId: message.id,
      text: message.content,
      settings: settings,
    ),
  );

  TextToSpeechRequest _speechRequestFor({
    required String messageId,
    required String text,
    required SettingsState? settings,
  }) {
    final ui = settings?.ui ?? const UiPrefs();
    return TextToSpeechRequest(
      messageId: messageId,
      text: text,
      rate: ui.ttsSpeed.speechRate,
      autoEmotion: ui.ttsAutoEmotion,
      apiConfig: settings?.ttsApi,
      apiKey: settings?.ttsApiKey ?? '',
    );
  }

  /// Opens hands-free voice mode on a plain text turn.
  Future<void> _startVoiceConversation() async {
    await _speech.stopAll();
    if (!mounted) return;
    if (_imageMode || _longTaskMode) {
      setState(() {
        _imageMode = false;
        _longTaskMode = false;
      });
    }
    await _voice.start();
  }

  /// One spoken turn goes through the normal send path (draft checks,
  /// attachments, rejection restore).
  Future<bool> _sendVoiceTurn(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return _send();
  }

  VoiceReply? _currentVoiceReply() {
    final state = ref.read(chatControllerProvider).value;
    final convo = state?.current;
    final last = convo?.activePath.lastOrNull;
    if (state == null ||
        convo == null ||
        last == null ||
        last.role != MessageRole.assistant) {
      return null;
    }
    return VoiceReply(
      messageId: last.id,
      content: last.content,
      failed: state.error != null && state.errorConvoId == convo.id,
    );
  }

  void _onSpeechChanged() {
    if (mounted) setState(() {});
  }

  void _showSpeechNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openModelSetup() async {
    await showModelSetup(context);
  }

  /// Sends the composer. Completes after the reply finished: true when the
  /// turn was accepted, false when it was rejected and the draft kept.
  Future<bool> _send({bool forceDocumentEdit = false}) async {
    final epoch = _composerEpoch;
    if (_picking) {
      _showAttachmentNotice('附件正在准备，请稍候再发送。');
      return false;
    }
    if (_speech.listening || _speech.busy) await _speech.cancelSpeech();
    if (!_isComposerCurrent(epoch)) return false;
    if (_pendingImagePicks != null) {
      _showAttachmentNotice('请先确认或取消待添加的图片');
      return false;
    }
    final text = _input.text;
    final settings = ref.read(settingsControllerProvider).value;
    if (forceDocumentEdit) {
      if (settings == null || !settings.supportsDocumentEdit) {
        _showAttachmentNotice('请先在设置中连接并发现支持文档编辑的 MCP Tools');
        return false;
      }
      if (!_attachments.any((a) => a.isEditableDocument)) {
        _showAttachmentNotice(
          '请先上传可编辑的 .xlsx / .docx / .pptx / .txt / .md / .csv / .tsv',
        );
        return false;
      }
      if (_imageMode) {
        _showAttachmentNotice('请先退出生图模式再改文档');
        return false;
      }
    } else if (text.trim().isEmpty && _attachments.isEmpty) {
      return false;
    }
    final useImageGeneration =
        !forceDocumentEdit &&
        _imageMode &&
        (settings?.imageGenerationConfigured ?? false);
    final useLongTask =
        !forceDocumentEdit &&
        _longTaskMode &&
        (settings?.supportsLongTasks ?? false) &&
        attachmentsAreDocuments(_attachments) &&
        !_imageMode;
    if (_longTaskMode && !useLongTask && !forceDocumentEdit) {
      _showAttachmentNotice(
        (settings?.supportsLongTasks ?? false)
            ? '长任务只支持文档附件，请移除图片后再发送。'
            : '当前服务不支持长任务，请关闭“长任务”后再发送。',
      );
      return false;
    }
    if (useImageGeneration) {
      if (text.trim().isEmpty) {
        _showAttachmentNotice(
          _attachments.any((a) => a.isImage) ? '图生图请写明如何修改参考图。' : '请描述要生成的图片。',
        );
        return false;
      }
      final nonImages = _attachments.where((a) => !a.isImage).toList();
      if (nonImages.isNotEmpty) {
        _showAttachmentNotice('生图模式仅支持图片参考，请移除非图片附件。');
        return false;
      }
    }
    final attachments = List<Attachment>.of(_attachments);
    _input.clear();
    setState(() {
      _attachments.clear();
      _longTaskMode = false;
    });
    _thinkingExpanded = true;
    _jumpToBottom();
    final chat = ref.read(chatControllerProvider.notifier);
    final accepted = useImageGeneration
        ? await chat.generateImage(
            text,
            referenceImages: [
              for (final a in attachments)
                if (a.isImage && a.hasImageData) a,
            ],
          )
        : useLongTask
        ? await chat.sendLongDocumentTask(text, attachments: attachments)
        : await chat.sendMessage(
            text,
            attachments: attachments,
            forceDocumentEdit: forceDocumentEdit,
          );
    // Rejected (e.g. API key 未配置 / 正在生成中) → restore the draft so the
    // user's input isn't lost. Only restore when the field is still empty, so
    // we don't clobber anything the user started typing during the await.
    if (!accepted &&
        _isComposerCurrent(epoch) &&
        _input.text.isEmpty &&
        _attachments.isEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
      setState(() {
        _attachments.addAll(attachments);
        _longTaskMode = useLongTask;
      });
    }
    return accepted;
  }

  static bool attachmentsAreDocuments(List<Attachment> attachments) =>
      attachments.isNotEmpty && attachments.every((a) => !a.isImage);

  static const _documentExtensions = AttachmentIngestor.documentExtensions;
  static const _imageExtensions = AttachmentIngestor.imageExtensions;

  Future<void> _pickDocuments() => _openAttachmentPicker();

  Future<void> _pickImages() =>
      _openAttachmentPicker(initialTab: AttachmentPickerTab.images);

  Future<void> _openLibraryPicker() =>
      _openAttachmentPicker(initialTab: AttachmentPickerTab.library);

  Future<void> _runAttachmentImport(
    Future<void> Function(int epoch) action,
  ) async {
    if (_picking || _pendingImagePicks != null) return;
    final epoch = _composerEpoch;
    setState(() => _picking = true);
    try {
      await action(epoch);
    } finally {
      if (_isComposerCurrent(epoch)) setState(() => _picking = false);
    }
  }

  Future<void> _openAttachmentPicker({
    AttachmentPickerTab initialTab = AttachmentPickerTab.recent,
  }) => _runAttachmentImport((epoch) async {
    final settings = ref.read(settingsControllerProvider).value;
    final forImageGeneration = _imageMode;
    final visionOk =
        settings?.canAttachImages(
          deepThink: ref.read(chatControllerProvider).value?.deepThink ?? false,
        ) ??
        false;
    if (forImageGeneration && !(settings?.imageGenerationConfigured ?? false)) {
      _showAttachmentNotice('请先在设置中配置图片生成 API。');
      return;
    }
    if (!forImageGeneration &&
        !visionOk &&
        initialTab == AttachmentPickerTab.images) {
      _showAttachmentNotice('当前模型不支持看图，请选择视觉模型或配置独立视觉 API。');
      return;
    }
    final maxSlots = _slotCap(
      forImageGeneration: forImageGeneration,
      imagesOnly: forImageGeneration,
    );
    final remaining = forImageGeneration
        ? (maxSlots - _attachments.where((a) => a.isImage).length).clamp(
            0,
            maxSlots,
          )
        : _maxAttachments - _attachments.length;
    if (remaining <= 0) {
      _showAttachmentNotice(
        forImageGeneration
            ? '图生图最多 $maxSlots 张参考图，请先移除部分图片。'
            : '最多可添加 $_maxAttachments 个附件。',
      );
      return;
    }
    final picked = await showAttachmentPicker(
      context,
      repository: ref.read(libraryRepositoryProvider),
      maxCount: remaining,
      allowImages: forImageGeneration || visionOk,
      allowDocuments: !forImageGeneration,
      initialTab: initialTab,
      isCurrent: () => _isComposerCurrent(epoch),
    );
    if (!_isComposerCurrent(epoch) ||
        picked == null ||
        picked.sources.isEmpty) {
      return;
    }
    await _ingestFileSources(
      picked.sources,
      epoch: epoch,
      imagesOnly: picked.sources.every(
        (s) => _imageExtensions.contains(s.extension),
      ),
      forImageGeneration: forImageGeneration,
      confirmImages: picked.confirmImages,
      slots: remaining,
    );
  });

  Future<void> _rememberInLibrary(Iterable<Attachment> attachments) async {
    final repo = ref.read(libraryRepositoryProvider);
    for (final attachment in attachments) {
      if (!attachment.hasDownloadableBytes) continue;
      try {
        await repo.importBytes(
          name: attachment.name,
          mimeType: attachment.mimeType,
          bytes: Uint8List.fromList(base64Decode(attachment.imageBase64!)),
        );
      } catch (_) {}
    }
  }

  Future<void> _handleComposerPaste() => _runAttachmentImport((epoch) async {
    if (_speech.listening) return;
    final streaming =
        ref.read(chatControllerProvider).value?.isStreaming ?? false;
    if (streaming) {
      await _pasteTextIntoComposer(epoch);
      return;
    }

    ClipboardMedia media = const ClipboardMedia();
    try {
      media = await readClipboardMedia();
    } catch (_) {}
    if (!_isComposerCurrent(epoch)) return;
    if (!media.hasAttachable) {
      await _pasteTextIntoComposer(epoch);
      return;
    }

    final settings = ref.read(settingsControllerProvider).value;
    final visionOk =
        settings?.canAttachImages(
          deepThink: ref.read(chatControllerProvider).value?.deepThink ?? false,
        ) ??
        false;
    final imageGenOk = settings?.imageGenerationConfigured ?? false;
    final forImageGeneration = _imageMode;
    if (forImageGeneration && !imageGenOk) {
      _showAttachmentNotice('请先在设置中配置图片生成 API。');
      return;
    }

    final sources = <FileIngestSource>[
      for (final path in media.filePaths)
        FileIngestSource(
          name: fileNameFromPath(path),
          extension: extensionOfName(fileNameFromPath(path)),
          path: path,
        ),
    ];
    if (sources.isEmpty && media.hasImage) {
      final identity = clipboardImageIdentity(media.imageBytes!);
      sources.add(
        FileIngestSource(
          name: identity.name,
          extension: identity.extension,
          bytes: media.imageBytes,
          reportedSize: media.imageBytes!.lengthInBytes,
        ),
      );
    }
    if (sources.isEmpty) {
      await _pasteTextIntoComposer(epoch);
      return;
    }

    final imageExts = _imageExtensions.toSet();
    final docExts = _documentExtensions.toSet();
    final allowImages = forImageGeneration || visionOk;
    final usable = [
      for (final source in sources)
        if ((imageExts.contains(source.extension) && allowImages) ||
            (docExts.contains(source.extension) && !forImageGeneration))
          source,
    ];
    final skippedUnsupported = sources.length - usable.length;
    if (usable.isEmpty) {
      if (!allowImages &&
          sources.every((s) => imageExts.contains(s.extension))) {
        _showAttachmentNotice(
          '当前模型不支持看图。请选用视觉模型（如 ${KnownModels.vision}），'
          '或在设置中配置独立视觉 API。',
        );
      } else if (forImageGeneration) {
        _showAttachmentNotice('生图模式只能粘贴图片作为参考图。');
      } else {
        _showAttachmentNotice('剪贴板里没有可附加的文件或图片。');
      }
      return;
    }

    final imagesOnly = usable.every((s) => imageExts.contains(s.extension));
    await _ingestFileSources(
      usable,
      epoch: epoch,
      imagesOnly: imagesOnly,
      forImageGeneration: forImageGeneration,
      confirmImages: false,
      extraNotice: skippedUnsupported > 0
          ? '跳过 $skippedUnsupported 个不支持的文件'
          : null,
    );
  });

  /// Applies the pending share after the conversation-switch listener has
  /// cleared the previous draft, so the shared content is not wiped with it.
  void _scheduleSharedPayload() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final payload = ref.read(pendingSharedPayloadProvider.notifier).take();
      if (payload != null) unawaited(_applySharedPayload(payload));
    });
  }

  /// Places shared text in the composer and shared files as attachments.
  /// Like voice input, nothing is sent until the user taps send.
  Future<void> _applySharedPayload(SharedPayload payload) async {
    if (payload.text.isNotEmpty) {
      final current = _input.text;
      final next = current.trim().isEmpty
          ? payload.text
          : '${current.trimRight()}\n${payload.text}';
      _input.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
    final nativeNotices = <String>[
      if (payload.tooLarge > 0) '跳过 ${payload.tooLarge} 个（单个最大 10 MB）',
      if (payload.tooMany > 0) '跳过 ${payload.tooMany} 个（最多 $_maxAttachments 个）',
      if (payload.unreadable > 0) '跳过 ${payload.unreadable} 个（无法读取）',
    ];
    if (payload.files.isEmpty) {
      if (nativeNotices.isNotEmpty) {
        _showAttachmentNotice(nativeNotices.join('；'));
      }
      return;
    }
    if (_picking || _pendingImagePicks != null) {
      _showAttachmentNotice('附件正在准备，分享的文件未添加，请稍后重新分享。');
      return;
    }
    await _runAttachmentImport((epoch) async {
      final settings = ref.read(settingsControllerProvider).value;
      final visionOk =
          settings?.canAttachImages(
            deepThink:
                ref.read(chatControllerProvider).value?.deepThink ?? false,
          ) ??
          false;
      final imageExts = _imageExtensions.toSet();
      final docExts = _documentExtensions.toSet();
      final sources = <FileIngestSource>[
        for (final file in payload.files)
          FileIngestSource(
            name: file.name.isEmpty ? fileNameFromPath(file.path) : file.name,
            extension: extensionOfName(
              file.name.isEmpty ? fileNameFromPath(file.path) : file.name,
            ),
            path: file.path,
            reportedSize: file.size,
          ),
      ];
      final images = sources.where((s) => imageExts.contains(s.extension));
      final usable = [
        for (final source in sources)
          if ((visionOk && imageExts.contains(source.extension)) ||
              docExts.contains(source.extension))
            source,
      ];
      final notices = [...nativeNotices];
      if (!visionOk && images.isNotEmpty) {
        notices.add('当前模型不支持看图，跳过 ${images.length} 张图片');
      }
      final unsupported = sources
          .where(
            (s) =>
                !imageExts.contains(s.extension) &&
                !docExts.contains(s.extension),
          )
          .length;
      if (unsupported > 0) notices.add('跳过 $unsupported 个不支持的文件');
      if (usable.isEmpty) {
        if (notices.isNotEmpty) _showAttachmentNotice(notices.join('；'));
        return;
      }
      await _ingestFileSources(
        usable,
        epoch: epoch,
        imagesOnly: usable.every((s) => imageExts.contains(s.extension)),
        confirmImages: false,
        extraNotice: notices.isEmpty ? null : notices.join('；'),
      );
    });
  }

  Future<void> _pasteTextIntoComposer(int epoch) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !_isComposerCurrent(epoch)) return;
    _insertTextIntoComposer(text);
  }

  void _insertTextIntoComposer(String text) {
    final value = _input.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start;
    final end = selection.end;
    final next = value.text.replaceRange(start, end, text);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  Future<void> _ingestFileSources(
    List<FileIngestSource> sources, {
    required int epoch,
    required bool imagesOnly,
    bool forImageGeneration = false,
    bool confirmImages = true,
    int? slots,
    String? extraNotice,
  }) async {
    if (sources.isEmpty || !_isComposerCurrent(epoch)) return;
    final settings = ref.read(settingsControllerProvider).value;
    final maxSlots = _slotCap(
      forImageGeneration: forImageGeneration,
      imagesOnly: imagesOnly,
    );
    final remaining =
        slots ??
        (forImageGeneration && imagesOnly
            ? (maxSlots - _attachments.where((a) => a.isImage).length).clamp(
                0,
                maxSlots,
              )
            : _maxAttachments - _attachments.length);
    if (remaining <= 0) {
      _showAttachmentNotice(
        forImageGeneration && imagesOnly
            ? (maxSlots <= 1
                  ? '图生图每次仅支持 1 张参考图，请先移除当前图片。'
                  : '图生图最多 $maxSlots 张参考图，请先移除部分图片。')
            : '最多可添加 $_maxAttachments 个附件。',
      );
      return;
    }

    final result =
        await AttachmentIngestor(parser: ref.read(fileParserProvider)).ingest(
          sources,
          slots: remaining,
          existingBytes: _attachments.fold<int>(
            0,
            (total, a) => total + a.sizeBytes,
          ),
          isCurrent: () => _isComposerCurrent(epoch),
        );
    if (result.cancelled || !_isComposerCurrent(epoch)) return;
    final additions = result.attachments;
    final tooMany = result.tooMany;
    final tooLarge = result.tooLarge;
    final overTotal = result.overTotal;
    final unreadable = result.unreadable;
    final notices = <String>[];
    if (tooMany > 0) {
      final cap = forImageGeneration && imagesOnly
          ? (settings?.imageGenerationApi.maxImageEditReferences ?? 1)
          : _maxAttachments;
      notices.add(
        forImageGeneration && imagesOnly
            ? '跳过 $tooMany 个（图生图最多 $cap 张参考图）'
            : '跳过 $tooMany 个（最多 $_maxAttachments 个）',
      );
    }
    if (tooLarge > 0) {
      notices.add('跳过 $tooLarge 个（单个最大 10 MB）');
    }
    if (overTotal > 0) notices.add('跳过 $overTotal 个（总计最大 48 MB）');
    if (unreadable > 0) notices.add('跳过 $unreadable 个（无法读取）');
    if (extraNotice != null && extraNotice.isNotEmpty) notices.add(extraNotice);

    if (additions.isNotEmpty && mounted) {
      if (imagesOnly) {
        final usable = [
          for (final a in additions)
            if (a.parseError == null && a.hasImageData) a,
        ];
        final broken = additions.length - usable.length;
        if (broken > 0) {
          notices.add('跳过 $broken 个无效图片');
        }
        if (usable.isEmpty) {
          notices.add('没有可用的图片');
        } else if (confirmImages) {
          setState(() {
            _pendingImageForGen = forImageGeneration;
            _pendingImageMaxSlots = remaining;
            _pendingImagePicks = [
              for (var i = 0; i < usable.length; i++)
                PendingImagePick(
                  attachment: usable[i],
                  selected: remaining <= 1 ? i == 0 : i < remaining,
                ),
            ];
          });
        } else {
          _attachImagesDirectly(
            usable,
            forImageGeneration: forImageGeneration,
            maxSlots: remaining,
          );
        }
      } else {
        setState(() {
          _attachments.addAll(additions);
          if (additions.any((a) => a.truncated) &&
              (ref.read(settingsControllerProvider).value?.supportsLongTasks ??
                  false)) {
            _longTaskMode = true;
          }
        });
        unawaited(_rememberInLibrary(additions));
      }
    }
    if (notices.isNotEmpty) _showAttachmentNotice(notices.join('；'));
  }

  void _attachImagesDirectly(
    List<Attachment> images, {
    required bool forImageGeneration,
    required int maxSlots,
  }) {
    final take = images.take(maxSlots.clamp(1, 64)).toList();
    if (take.isEmpty) return;
    final singleRefReplace =
        forImageGeneration &&
        (ref
                    .read(settingsControllerProvider)
                    .value
                    ?.imageGenerationApi
                    .maxImageEditReferences ??
                1) <=
            1;
    setState(() {
      if (singleRefReplace) {
        _attachments.removeWhere((a) => a.isImage);
      }
      _attachments.addAll(take);
    });
    unawaited(_rememberInLibrary(take));
  }

  void _showAttachmentNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _removeAttachment(String id) {
    setState(() {
      _attachments.removeWhere((a) => a.id == id);
      if (!attachmentsAreDocuments(_attachments)) _longTaskMode = false;
    });
  }

  void _cancelPendingImages() {
    setState(() {
      _pendingImagePicks = null;
      _pendingImageForGen = false;
    });
  }

  void _confirmPendingImages() {
    final pending = _pendingImagePicks;
    if (pending == null || pending.isEmpty) return;
    final chosen = [
      for (final p in pending)
        if (p.selected && p.attachment.hasImageData) p.attachment,
    ];
    if (chosen.isEmpty) {
      _showAttachmentNotice('请至少勾选一张图片');
      return;
    }
    // [_pendingImageMaxSlots] is remaining capacity computed at pick time.
    final take = chosen.take(_pendingImageMaxSlots.clamp(1, 64)).toList();
    final forGen = _pendingImageForGen;
    final singleRefReplace =
        forGen &&
        (ref
                    .read(settingsControllerProvider)
                    .value
                    ?.imageGenerationApi
                    .maxImageEditReferences ??
                1) <=
            1;
    setState(() {
      if (singleRefReplace) {
        _attachments.removeWhere((a) => a.isImage);
      }
      _attachments.addAll(take);
      _pendingImagePicks = null;
      _pendingImageForGen = false;
    });
    unawaited(_rememberInLibrary(take));
  }

  Future<void> _openConversationMcpPicker() async {
    final settings = ref.read(settingsControllerProvider).value;
    final current = ref.read(chatControllerProvider).value?.current;
    if (settings == null || current == null) return;
    final choices = settings.availableMcpServers;
    if (choices.isEmpty) return;
    final selected = current.customMcpServerIds.toSet();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        var next = {...selected};
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '这个对话使用的 MCP',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '只把勾选的服务器工具交给模型。新对话默认不勾选。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    for (final choice in choices)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(choice.name),
                        subtitle: Text(
                          choice.toolsDiscovered ? '已发现工具' : '尚未发现工具，先在设置里连接',
                        ),
                        value: next.contains(choice.id),
                        onChanged: (checked) {
                          setSheetState(() {
                            if (checked == true) {
                              next.add(choice.id);
                            } else {
                              next.remove(choice.id);
                            }
                          });
                        },
                      ),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, [
                        for (final choice in choices)
                          if (next.contains(choice.id)) choice.id,
                      ]),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (result == null || !mounted) return;
    ref.read(chatControllerProvider.notifier).setCustomMcpServerIds(result);
  }

  bool _confirmingStepRetry = false;
  Future<void> _retryProcessStep(
    String convoId,
    String msgId,
    SearchActivity step,
  ) async {
    if (_confirmingStepRetry) return;
    _confirmingStepRetry = true;
    try {
      var confirmed = !step.retryNeedsConfirmation;
      if (!confirmed) {
        confirmed =
            await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                title: const Text('重新提交生图？'),
                content: const Text(
                  '这将发起一次新的收费请求。停止本地等待不代表远端已取消；'
                  '如果上次状态不明，请先在服务商处检查结果，避免重复扣费。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('先检查'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('确认重新提交'),
                  ),
                ],
              ),
            ) ??
            false;
      }
      if (!mounted || !confirmed) return;
      await ref
          .read(chatControllerProvider.notifier)
          .retryTaskStep(
            convoId,
            msgId,
            step.id,
            confirmedPaidRequest: confirmed,
          );
    } finally {
      _confirmingStepRetry = false;
    }
  }

  void _toggleImageMode() {
    if (_picking || _pendingImagePicks != null) return;
    if (_imageMode) {
      setState(() => _imageMode = false);
      return;
    }
    // Entering 生图: drop non-images; cap refs by model capability.
    final settings = ref.read(settingsControllerProvider).value;
    final maxRefs = settings?.imageGenerationApi.maxImageEditReferences ?? 1;
    final images = [
      for (final a in _attachments)
        if (a.isImage && a.hasImageData) a,
    ];
    final droppedDocs = _attachments.any((a) => !a.isImage);
    final kept = images.take(maxRefs).toList();
    setState(() {
      _attachments
        ..clear()
        ..addAll(kept);
      _imageMode = true;
      _longTaskMode = false;
    });
    if (droppedDocs) {
      _showAttachmentNotice('生图模式仅保留图片作为参考，已移除非图片附件。');
    } else if (images.length > maxRefs) {
      _showAttachmentNotice(
        maxRefs <= 1
            ? '图生图每次仅使用 1 张参考图。'
            : '当前模型最多 $maxRefs 张参考图，已保留前 $maxRefs 张。',
      );
    }
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

  Future<void> _rememberMessage(
    Conversation conversation,
    ChatMessage message,
  ) async {
    final flattened = message.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final draft = flattened.characters.length > MemorySafety.maxContentChars
        ? flattened.characters
              .take(MemorySafety.maxContentChars)
              .toList()
              .join()
        : flattened;
    final textController = TextEditingController(text: draft);
    String? validationError;
    final content = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('记住这条内容'),
          content: SizedBox(
            width: 520,
            child: TextField(
              controller: textController,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              maxLength: MemorySafety.maxContentChars,
              decoration: InputDecoration(
                labelText: conversation.projectId == null
                    ? '保存为全局记忆'
                    : '仅保存在当前项目',
                helperText: '保存前请整理为准确、独立的一条事实或偏好。',
                helperMaxLines: 2,
                errorText: validationError,
                alignLabelWithHint: true,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final normalized = MemorySafety.normalize(
                    textController.text,
                  );
                  Navigator.of(dialogContext).pop(normalized);
                } on MemoryValidationException catch (error) {
                  setDialogState(() => validationError = error.message);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    textController.dispose();
    if (content == null || !mounted) return;
    try {
      final result = await ref
          .read(memoryControllerProvider.notifier)
          .add(
            content: content,
            sourceConversationId: conversation.id,
            projectId: conversation.projectId,
            sourceMessageId: message.id,
            sourceRole: message.role.wire,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.created ? '已写入长期记忆' : '这条记忆已经存在'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存记忆失败：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _extractMemoryCandidates(Conversation conversation) async {
    if (_extractingMemoryCandidates) return;
    if (conversation.isStoryLike) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('故事与角色内容不会整理到全局记忆。'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (ref.read(chatControllerProvider).value?.isStreaming == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请等待当前回复完成后再整理记忆。'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _extractingMemoryCandidates = true);
    final cancelToken = CancelToken();
    _memoryCandidateCancelToken = cancelToken;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(child: Text('正在从当前会话整理候选记忆…')),
            ],
          ),
          duration: Duration(seconds: 30),
          behavior: SnackBarBehavior.floating,
        ),
      );

    try {
      final settings = await ref.read(settingsControllerProvider.future);
      if (!settings.memoryEnabled) {
        throw const MemoryCandidateFormatException('请先在设置中开启“长期记忆”。');
      }
      final repository = ref.read(memoryRepositoryProvider);
      final existing = await repository.load(refresh: true);
      final chatModel = settings.active?.chatModel ?? settings.model;
      final candidates = await ref
          .read(memoryCandidateServiceProvider)
          .extract(
            config: settings.config.copyWith(model: chatModel),
            messages: conversation.activePath,
            existingMemories: existing.entries
                .where((e) => e.projectId == conversation.projectId)
                .toList(),
            cancelToken: cancelToken,
          );
      if (!mounted || cancelToken.isCancelled) return;
      messenger.hideCurrentSnackBar();

      if (candidates.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('没有发现值得长期保存的新信息。'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final selected =
          await showModalBottomSheet<List<MemoryCandidateSelection>>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => MemoryCandidateReviewSheet(candidates: candidates),
          );
      if (!mounted || selected == null || selected.isEmpty) return;

      final result = await ref
          .read(memoryControllerProvider.notifier)
          .applyConfirmedCandidates(
            selected,
            sourceConversationId: conversation.id,
            projectId: conversation.projectId,
          );
      if (!mounted) return;
      final summary = <String>[
        if (result.added > 0) '新增 ${result.added} 条',
        if (result.replaced > 0) '替换 ${result.replaced} 条',
        if (result.skipped > 0) '跳过 ${result.skipped} 条',
      ];
      messenger.showSnackBar(
        SnackBar(
          content: Text(summary.isEmpty ? '没有写入新的长期记忆' : summary.join('，')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted || cancelToken.isCancelled) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('整理候选记忆失败：$error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } finally {
      if (identical(_memoryCandidateCancelToken, cancelToken)) {
        _memoryCandidateCancelToken = null;
      }
      if (mounted) setState(() => _extractingMemoryCandidates = false);
    }
  }

  String? _characterNameFor(Conversation? convo) {
    if (convo == null || !convo.isStory) return null;
    return _characterNameForId(convo.characterId);
  }

  String? _characterNameForId(String? characterId) {
    if (characterId == null) return null;
    final cards = ref.watch(characterCardsProvider).value;
    if (cards == null) return null;
    for (final c in cards) {
      if (c.id == characterId) return c.name;
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
    final slice = ref.watch(
      chatControllerProvider.select(_ChatScaffoldSlice.from),
    );
    final controller = ref.read(chatControllerProvider.notifier);

    // Auto-scroll as content streams in (only while stuck to the bottom).
    // Switching conversations resumes following and snaps to the latest turn.
    ref.listen(chatControllerProvider, (prev, next) {
      if (prev?.value?.currentId != next.value?.currentId) {
        if (_voice.active) unawaited(_voice.exit());
        _composerEpoch++;
        if (prev?.value?.currentId != null) {
          unawaited(_speech.stopAll());
        } else {
          unawaited(_speech.cancelSpeech());
        }
        _stick = true;
        _messageKeys.clear();
        if (_selecting) {
          _selecting = false;
          _selectedIds.clear();
        }
        // Do not carry composer draft / reference images across conversations.
        if (_picking ||
            _longTaskMode ||
            _attachments.isNotEmpty ||
            _input.text.isNotEmpty ||
            _imageMode ||
            _pendingImagePicks != null) {
          setState(() {
            _picking = false;
            _attachments.clear();
            _input.clear();
            _imageMode = false;
            _longTaskMode = false;
            _pendingImagePicks = null;
            _pendingImageForGen = false;
          });
        }
      }
      if (_voice.phase == VoiceConversationPhase.replying) {
        final value = next.value;
        final reply = _currentVoiceReply();
        if (reply != null &&
            value != null &&
            value.streamingConvoId == value.currentId) {
          _voice.onReplyProgress(reply);
        }
      }
      _scrollToBottom();
    });

    ref.listen<SharedPayload?>(pendingSharedPayloadProvider, (prev, next) {
      if (next != null) _scheduleSharedPayload();
    });

    // History search “定位” → scroll to a specific message once the list
    // has built GlobalKeys for the new conversation's bubbles.
    ref.listen<String?>(pendingJumpMessageIdProvider, (prev, next) {
      final id = next;
      if (id == null || id.isEmpty) return;
      // Capture messenger before any async gap (use_build_context_synchronously).
      final messenger = ScaffoldMessenger.maybeOf(context);
      void tryJump([int attempt = 0]) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final path =
              ref.read(chatControllerProvider).value?.current?.activePath ??
              const <ChatMessage>[];
          final index = path.indexWhere((m) => m.id == id);
          if (_messageKeys[id]?.currentContext != null) {
            _scrollToMessage(id);
            ref.read(pendingJumpMessageIdProvider.notifier).clear();
            return;
          }
          // ListView.builder only builds visible rows — jump near the index
          // first so the target key can materialize.
          if (index >= 0 && _scroll.hasClients) {
            final max = _scroll.position.maxScrollExtent;
            final est = path.isEmpty ? 0.0 : (index / path.length) * max;
            _programmaticScroll = true;
            _stick = false;
            try {
              await _scroll.animateTo(
                est.clamp(0.0, max),
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              );
            } catch (_) {
              // ignore scroll races during conversation switch
            } finally {
              _programmaticScroll = false;
            }
            if (!mounted) return;
            if (_messageKeys[id]?.currentContext != null) {
              _scrollToMessage(id);
              ref.read(pendingJumpMessageIdProvider.notifier).clear();
              return;
            }
          }
          if (attempt < 20) {
            tryJump(attempt + 1);
          } else {
            ref.read(pendingJumpMessageIdProvider.notifier).clear();
            if (!mounted) return;
            messenger?.showSnackBar(
              const SnackBar(content: Text('无法定位到该消息（可能不在当前分支）')),
            );
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
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _handleComposerPaste,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            _handleComposerPaste,
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ownsWorkspaceSidebar = !widget.desktopShell;
            final dualPane =
                constraints.maxWidth >= WorkspaceBreakpoints.dualPane;
            final triplePane =
                constraints.maxWidth >= WorkspaceBreakpoints.triplePane;
            final storyLike = slice.isStory || slice.isEnsemble;
            final showHistory =
                ownsWorkspaceSidebar && dualPane && _historyOpen;
            final showTools = triplePane && storyLike && _toolsOpen;
            final showOutline =
                dualPane && _outlineOpen && slice.hasCurrent && !showTools;
            final scheme = Theme.of(context).colorScheme;
            final speakerName = _characterNameForId(
              slice.isStory ? slice.characterId : null,
            );
            final mode = slice.mode;
            final modeColor = ModeStyle.color(mode);
            final titleText = slice.isEnsemble
                ? (slice.title.isNotEmpty ? slice.title : '角色大乱斗')
                : slice.isStory
                ? (speakerName ?? (slice.title.isNotEmpty ? slice.title : '故事'))
                : (slice.title.isNotEmpty ? slice.title : 'Expert Chat');
            final beats = parseOutlineBeats(slice.outline);
            final beatProgress = !slice.hasCurrent || !slice.isStory
                ? null
                : beats.isEmpty
                ? null
                : '节拍 ${slice.plotCursor.clamp(0, beats.length)}/${beats.length}';
            final settings = ref.watch(settingsControllerProvider).value;
            final contextEnabled = settings?.context.enabled ?? false;
            final canShowMemoryCandidates =
                slice.hasCurrent && !storyLike && slice.hasUserActivity;
            final canExtractMemoryCandidates =
                canShowMemoryCandidates &&
                settings?.memoryEnabled == true &&
                !slice.isStreaming &&
                !_extractingMemoryCandidates;
            final contextReport = slice.currentId == null
                ? null
                : ref.watch(
                    chatControllerProvider.select(
                      (async) => async.value?.contextReports,
                    ),
                  )?[slice.currentId!];
            final contextInputBudget = settings?.context.inputBudgetTokens ?? 0;
            final showWorkMode =
                slice.hasCurrent &&
                !slice.isStory &&
                !slice.isEnsemble &&
                !slice.isStudy;
            return Scaffold(
              appBar: AppBar(
                centerTitle: false,
                toolbarHeight: constraints.maxWidth < 600 && showWorkMode
                    ? 72
                    : null,
                titleSpacing: dualPane ? 20 : 8,
                title: LayoutBuilder(
                  builder: (context, constraints) {
                    final compactTitle =
                        showWorkMode && constraints.maxWidth < 240;
                    final modeIcon = Container(
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
                    );
                    final titleBlock = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(titleText, overflow: TextOverflow.ellipsis),
                        if (slice.hasCurrent && storyLike)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ModePill(
                                  label: slice.hasLocalCast
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
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () {
                                    final convo = ref
                                        .read(chatControllerProvider)
                                        .value
                                        ?.current;
                                    if (convo != null) {
                                      _openPlot(convo, canPinTools: triplePane);
                                    }
                                  },
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
                            ),
                          ),
                      ],
                    );
                    return SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight.isFinite
                          ? constraints.maxHeight
                          : 56,
                      child: Row(
                        children: [
                          if (!compactTitle) ...[
                            modeIcon,
                            const SizedBox(width: 8),
                          ],
                          if (showWorkMode && compactTitle)
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    titleText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                                  ChatWorkModeSwitch(
                                    workMode: slice.workMode,
                                    onChanged: controller.setWorkMode,
                                  ),
                                ],
                              ),
                            )
                          else ...[
                            Expanded(child: titleBlock),
                            if (showWorkMode) ...[
                              const SizedBox(width: 8),
                              ChatWorkModeSwitch(
                                workMode: slice.workMode,
                                onChanged: controller.setWorkMode,
                              ),
                            ],
                          ],
                        ],
                      ),
                    );
                  },
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
                        child: ContextUsageChip(
                          compact: constraints.maxWidth < 480,
                          report: contextReport,
                          inputBudget: contextInputBudget,
                        ),
                      ),
                    ),
                  if (ownsWorkspaceSidebar && dualPane)
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
                  if (slice.hasCurrent && dualPane)
                    IconButton(
                      tooltip: _outlineOpen ? '隐藏大纲' : '大纲',
                      icon: Icon(
                        _outlineOpen ? Icons.list_alt : Icons.list_alt_outlined,
                      ),
                      onPressed: () => _toggleOutline(wide: true),
                    ),
                  if (triplePane && storyLike)
                    IconButton(
                      tooltip: _toolsOpen ? '隐藏情节面板' : '显示情节面板',
                      icon: Icon(
                        _toolsOpen
                            ? Icons.vertical_split
                            : Icons.vertical_split_outlined,
                      ),
                      onPressed: () => setState(() {
                        _toolsOpen = !_toolsOpen;
                        if (_toolsOpen) _outlineOpen = false;
                      }),
                    ),
                  if (!widget.desktopShell)
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
                          ),
                        ),
                      ],
                    ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (v) {
                      final current = ref
                          .read(chatControllerProvider)
                          .value
                          ?.current;
                      if (v == 'outline') {
                        _toggleOutline(wide: dualPane);
                      } else if (v == 'export') {
                        unawaited(_export(current));
                      } else if (v == 'memory_candidates' && current != null) {
                        unawaited(_extractMemoryCandidates(current));
                      }
                    },
                    itemBuilder: (_) => [
                      if (slice.hasCurrent)
                        const PopupMenuItem(
                          value: 'outline',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.list_alt_outlined),
                            title: Text('大纲'),
                          ),
                        ),
                      const PopupMenuItem(
                        value: 'export',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.ios_share_outlined),
                          title: Text('导出 Markdown'),
                        ),
                      ),
                      if (canShowMemoryCandidates)
                        PopupMenuItem(
                          value: 'memory_candidates',
                          enabled: canExtractMemoryCandidates,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: _extractingMemoryCandidates
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.auto_awesome_outlined),
                            title: Text(
                              _extractingMemoryCandidates
                                  ? '正在整理候选记忆…'
                                  : '整理候选记忆',
                            ),
                            subtitle: Text(
                              settings?.memoryEnabled != true
                                  ? '请先在设置中开启长期记忆'
                                  : slice.isStreaming
                                  ? '当前回复完成后可用'
                                  : '从当前会话提取，确认后才写入',
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              drawer: ownsWorkspaceSidebar && !dualPane
                  ? const _HistoryDrawer()
                  : null,
              body: Row(
                children: [
                  if (showHistory) ...[
                    SizedBox(
                      width: _historyWidth,
                      child: const ChatWorkspaceSidebar(),
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
                    child: slice.isLoading
                        ? const Center(child: CircularProgressIndicator())
                        : slice.hasError
                        ? Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(20),
                              child: RecoveryNotice(
                                error: slice.loadError!,
                                title: '会话暂时无法加载',
                                onRetry: () async {
                                  ref.invalidate(chatControllerProvider);
                                  await ref.read(chatControllerProvider.future);
                                },
                              ),
                            ),
                          )
                        : _chatColumn(
                            slice,
                            controller,
                            canPinTools: triplePane,
                          ),
                  ),
                  if (showOutline) ...[
                    _PaneResizeHandle(
                      onDrag: (dx) {
                        setState(() {
                          _outlineWidth = (_outlineWidth - dx).clamp(
                            220.0,
                            420.0,
                          );
                        });
                      },
                    ),
                    SizedBox(
                      width: _outlineWidth,
                      child: Consumer(
                        builder: (context, ref, _) {
                          final path =
                              ref.watch(
                                chatControllerProvider.select(
                                  (async) => async.value?.current?.activePath,
                                ),
                              ) ??
                              const <ChatMessage>[];
                          return ConversationOutlinePanel(
                            entries: buildConversationOutline(path),
                            onJump: _jumpToOutline,
                            onClose: () => setState(() => _outlineOpen = false),
                          );
                        },
                      ),
                    ),
                  ],
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
                        key: ValueKey('tools-${slice.currentId}'),
                        conversationId: slice.currentId!,
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
    _ChatScaffoldSlice slice,
    ChatController controller, {
    required bool canPinTools,
  }) {
    final convo = ref.read(chatControllerProvider).value?.current;
    final speakerName = _characterNameFor(convo);
    final showError =
        slice.error != null &&
        (slice.errorConvoId == null || slice.errorConvoId == slice.currentId);
    final needsSetup =
        showError && AppFailure.from(slice.error!).needsConfiguration;
    final settings = ref.watch(settingsControllerProvider).value;
    final ui = settings?.ui ?? const UiPrefs();
    return Column(
      children: [
        if (convo?.recoveredStorage.isNotEmpty == true)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('部分会话资料无法读取，原始数据已保留。请先导出完整备份，再联系维护者处理。'),
          ),
        if (showError && slice.error != null)
          RecoveryNotice(
            error: slice.error!,
            secrets: [
              if (settings != null) settings.apiKey,
              if (settings != null) settings.searchApiKey,
              if (settings != null) settings.imageGenerationApiKey,
            ],
            onRetry:
                slice.isStreaming ||
                    slice.retryConversationId == null ||
                    slice.retryConversationId != slice.currentId
                ? null
                : () => controller.retryLast(),
            onConfigure: needsSetup
                ? () {
                    if (settings?.config.isReady ?? false) {
                      openShellTab(ref, ShellTab.settings);
                    } else {
                      _openModelSetup();
                    }
                  }
                : null,
          ),
        if (convo != null && slice.isStory)
          _StorySessionBar(
            conversation: convo,
            characterName: slice.hasLocalCast
                ? '导演模式 · ${slice.localCastLength} 位角色'
                : speakerName,
            onOpenPlot: () => _openPlot(convo, canPinTools: canPinTools),
            onAdvance: slice.isStreaming ? null : controller.advancePlot,
            onContinue: slice.isStreaming || !slice.hasLocalCast
                ? null
                : controller.continueCurrentScene,
            onNudgeBack: () => controller.adjustPlotCursor(-1),
            onNudgeForward: () => controller.adjustPlotCursor(1),
          ),
        if (convo != null && slice.isEnsemble)
          _EnsembleSessionBar(
            conversation: convo,
            busy: slice.isStreaming,
            onNext: slice.isStreaming ? null : controller.ensembleNextTurn,
            onAuto: slice.isStreaming
                ? null
                : () => controller.ensembleAutoPlay(rounds: 6),
            onOpenPlot: () => _openPlot(convo, canPinTools: canPinTools),
          ),
        Expanded(
          child: Consumer(
            builder: (context, ref, _) => _buildMessageList(ref, ui),
          ),
        ),
        if (_selecting)
          _SelectionShareBar(
            count: _selectedIds.length,
            onCancel: _exitSelect,
            onCopy: () {
              final current = ref.read(chatControllerProvider).value?.current;
              _copySelectedMarkdown(
                current?.activePath ?? const <ChatMessage>[],
                current,
              );
            },
            onShare: () {
              final current = ref.read(chatControllerProvider).value?.current;
              _shareSelected(
                current?.activePath ?? const <ChatMessage>[],
                current,
              );
            },
          ),
        if (!_selecting &&
            _pendingImagePicks != null &&
            _pendingImagePicks!.isNotEmpty)
          ImagePickConfirmBar(
            candidates: _pendingImagePicks!,
            maxSelectable: _pendingImageMaxSlots.clamp(1, 64),
            onChanged: () => setState(() {}),
            onCancel: _cancelPendingImages,
            onConfirm: _confirmPendingImages,
          ),
        if (!_selecting && convo != null && convo.isStudy)
          StudySessionActions(conversation: convo),
        if (!_selecting && _voice.active)
          VoiceConversationPanel(controller: _voice),
        if (!_selecting && !_voice.active)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.55,
            ),
            child: CustomScrollView(
              shrinkWrap: true,
              slivers: [
                SliverToBoxAdapter(
                  child: ChatComposer(
                    controller: _input,
                    isStreaming: slice.isStreaming,
                    deepThink: slice.deepThink,
                    reasoningEffort: slice.reasoningEffort,
                    supportsReasoningEffort:
                        settings?.config.capabilities.supportsReasoningEffort ??
                        false,
                    searchMode: slice.searchMode,
                    imageGenMode: slice.imageGenMode,
                    attachments: _attachments,
                    picking: _picking,
                    storyLike: slice.isStory || slice.isEnsemble,
                    isStudy: slice.isStudy,
                    directorMode: slice.hasLocalCast,
                    canAttachImages:
                        settings?.canAttachImages(deepThink: slice.deepThink) ??
                        false,
                    imageGenerationConfigured:
                        settings?.imageGenerationConfigured ?? false,
                    imageMode:
                        _imageMode &&
                        (settings?.imageGenerationConfigured ?? false),
                    longTaskMode: _longTaskMode,
                    longTaskAvailable:
                        (settings?.supportsLongTasks ?? false) &&
                        attachmentsAreDocuments(_attachments) &&
                        !_imageMode,
                    maxImageEditReferences:
                        settings?.imageGenerationApi.maxImageEditReferences ??
                        1,
                    documentEditAvailable:
                        (settings?.supportsDocumentEdit ?? false) &&
                        _attachments.any((a) => a.isEditableDocument) &&
                        !_imageMode,
                    speechBusy: _speech.busy,
                    speechListening: _speech.listening,
                    speechUsesCloudAsr: _speech.usesCloudAsr,
                    onToggleDeepThink: controller.toggleDeepThink,
                    onReasoningEffortChanged: controller.setReasoningEffort,
                    mcpAvailable:
                        (settings?.availableMcpServers.isNotEmpty ?? false) &&
                        !slice.isStory &&
                        !slice.isEnsemble &&
                        !slice.isStudy,
                    mcpSelectedCount: slice.customMcpServerIds.isEmpty
                        ? 0
                        : slice.customMcpServerIds.split(',').length,
                    onToggleSearch: controller.toggleSearch,
                    onPickMcpServers: _openConversationMcpPicker,
                    onSetImageGenMode: controller.setImageGenMode,
                    onToggleImageMode: _toggleImageMode,
                    onToggleLongTask: () =>
                        setState(() => _longTaskMode = !_longTaskMode),
                    onPickDocuments: _pickDocuments,
                    onPickImages: _pickImages,
                    onPickLibrary: _openLibraryPicker,
                    onPaste: _handleComposerPaste,
                    onRemoveAttachment: _removeAttachment,
                    onToggleSpeech: _speech.toggleSpeech,
                    onVoiceConversation: kIsWeb
                        ? null
                        : _startVoiceConversation,
                    onSend: () => _send(),
                    onDocumentEdit: () => _send(forceDocumentEdit: true),
                    onStop: controller.stop,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMessageList(WidgetRef ref, UiPrefs ui) {
    final state = ref.watch(chatControllerProvider).value;
    final convo = state?.current;
    final messages = convo?.activePath ?? const <ChatMessage>[];
    final streamingHere = convo != null && state?.streamingConvoId == convo.id;
    final speakerName = _characterNameFor(convo);
    final settings = ref.watch(settingsControllerProvider).value;
    final memory = settings?.memoryEnabled == true
        ? ref.watch(memoryControllerProvider).value
        : null;
    final rememberedMessageIds = {
      for (final entry in memory?.entries ?? const <MemoryEntry>[])
        if (entry.sourceMessageId != null) entry.sourceMessageId!,
    };
    final contentMax = ui.contentWidth.maxWidth;
    final densityPad = ui.density == DensityPref.compact
        ? const EdgeInsets.fromLTRB(16, 12, 16, 20)
        : const EdgeInsets.fromLTRB(24, 18, 24, 28);
    final controller = ref.read(chatControllerProvider.notifier);
    if (messages.isEmpty) {
      return Consumer(
        builder: (context, ref, _) => _EmptyState(
          needsSetup:
              !(ref.watch(settingsControllerProvider).value?.config.isReady ??
                  false),
          onSetup: _openModelSetup,
          onExample: (text) {
            if (_input.text.trim().isEmpty) {
              _input.text = text;
              _input.selection = TextSelection.collapsed(offset: text.length);
            }
          },
        ),
      );
    }
    return Stack(
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
                final ttsForMessage = _speech.playback.isFor(m.id);
                return KeyedSubtree(
                  key: _keyForMessage(m.id),
                  child: MessageBubble(
                    key: ValueKey(m.id),
                    message: m,
                    onAnswerFromResults:
                        !_selecting &&
                            m.role == MessageRole.assistant &&
                            m.kind != MessageKind.generatedImage &&
                            !convo.isStoryLike &&
                            !convo.isStudy &&
                            ((streamingHere && isLastAssistant) ||
                                (state?.isStreaming != true &&
                                    m.searchActivities.any(
                                      (a) =>
                                          a.status == SearchActivityStatus.done,
                                    )))
                        ? () => unawaited(
                            controller.answerFromResults(convo.id, m.id),
                          )
                        : null,
                    onStopTask: streamingHere && isLastAssistant && !_selecting
                        ? controller.stop
                        : null,
                    onRetryStep: state?.isStreaming != true && !_selecting
                        ? (step) =>
                              unawaited(_retryProcessStep(convo.id, m.id, step))
                        : null,
                    isStreaming: streamingHere && isLastAssistant,
                    speakerName: m.role == MessageRole.assistant
                        ? (m.speakerName ?? speakerName)
                        : null,
                    userLabel: convo.localCast.isNotEmpty ? '导演' : null,
                    onRegenerate:
                        (isLastAssistant &&
                            state?.isStreaming != true &&
                            !_selecting &&
                            m.kind != MessageKind.generatedImage &&
                            m.longTask == null)
                        ? controller.regenerate
                        : null,
                    onCancelLongTask:
                        m.longTask?.isActive == true && !_selecting
                        ? () => unawaited(
                            controller.cancelLongTask(convo.id, m.id),
                          )
                        : null,
                    onRetryLongTask: m.longTask?.canRetry == true && !_selecting
                        ? () => unawaited(
                            controller.retryLongTask(convo.id, m.id),
                          )
                        : null,
                    onEdit:
                        (m.role == MessageRole.user &&
                            state?.isStreaming != true &&
                            !_selecting)
                        ? (text) => controller.editMessage(m.id, text)
                        : null,
                    onSpeak:
                        (m.role == MessageRole.assistant &&
                            m.content.trim().isNotEmpty &&
                            !_selecting)
                        ? () => _toggleTextToSpeech(m, settings)
                        : null,
                    isSpeechLoading:
                        ttsForMessage &&
                        _speech.playback.phase == TextToSpeechPhase.loading,
                    isSpeaking:
                        ttsForMessage &&
                        _speech.playback.phase == TextToSpeechPhase.speaking,
                    onRemember:
                        settings?.memoryEnabled == true &&
                            !_selecting &&
                            state?.isStreaming != true &&
                            m.content.trim().isNotEmpty
                        ? () => _rememberMessage(convo, m)
                        : null,
                    isRemembered: rememberedMessageIds.contains(m.id),
                    branchIndex: bIdx,
                    branchCount: bCount,
                    onPrevBranch: () => controller.switchBranch(m.id, -1),
                    onNextBranch: () => controller.switchBranch(m.id, 1),
                    messageStyle: ui.messageStyle,
                    markdownStyle: ui.markdownStyle,
                    liveMarkdown: ui.liveMarkdown,
                    onThinkingExpandedChanged: isLastAssistant
                        ? (expanded) {
                            _thinkingExpanded = expanded;
                            _reportStreamView();
                          }
                        : null,
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
        if (!_stick && !_selecting)
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: Center(child: _JumpToBottomButton(onTap: _jumpToBottom)),
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
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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
  const _HistoryDrawer();

  @override
  Widget build(BuildContext context) =>
      const Drawer(child: ChatWorkspaceSidebar());
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
    required this.onContinue,
    required this.onNudgeBack,
    required this.onNudgeForward,
  });

  final Conversation conversation;
  final String? characterName;
  final VoidCallback onOpenPlot;
  final VoidCallback? onAdvance;
  final VoidCallback? onContinue;
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
    final noteHint = conversation.authorNote.trim().isEmpty ? null : '导演指令已启用';
    final wiCount = conversation.worldInfoIds.length;
    final lengthBudget = StoryLengthBudget.forConversation(conversation);
    final lengthHint = lengthBudget?.sessionLabel();

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
                    if (lengthHint != null)
                      Text(
                        lengthHint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
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
              label: conversation.localCast.isNotEmpty ? '写下一场' : '推进情节',
              filled: true,
              color: accent,
              onPressed: onAdvance,
            ),
            if (conversation.localCast.isNotEmpty)
              IconButton(
                tooltip: '续写当前场',
                visualDensity: VisualDensity.compact,
                onPressed: onContinue,
                icon: const Icon(Icons.subdirectory_arrow_left, size: 20),
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
  const _EmptyState({
    required this.needsSetup,
    required this.onSetup,
    required this.onExample,
  });
  final bool needsSetup;
  final VoidCallback onSetup;
  final ValueChanged<String> onExample;

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
                        needsSetup
                            ? '先连接你使用的模型服务，验证成功后即可开始。'
                            : '写下你的问题，或从一个小任务开始。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: compact ? 1.35 : 1.5,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (needsSetup)
                        FilledButton.icon(
                          key: const ValueKey('chat-connect-model'),
                          onPressed: onSetup,
                          icon: const Icon(Icons.add),
                          label: const Text('连接模型，开始使用'),
                        )
                      else
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () =>
                                  onExample('帮我梳理一个问题，并给出清晰的行动步骤。'),
                              child: const Text('梳理思路'),
                            ),
                            OutlinedButton(
                              onPressed: () =>
                                  onExample('请帮我解读接下来提供的资料，提炼重点和待确认的问题。'),
                              child: const Text('解读资料'),
                            ),
                          ],
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
