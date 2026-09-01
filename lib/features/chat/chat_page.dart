import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/mode_style.dart';
import '../../core/providers.dart';
import '../../core/workspace_layout.dart';
import '../../data/conversation_repository.dart';
import '../../data/library_models.dart';
import '../../data/models.dart';
import '../../data/story_models.dart';
import '../../data/ui_prefs.dart';
import '../../domain/clipboard/clipboard_media.dart';
import '../../domain/chat/conversation_outline.dart';
import '../../domain/context/context_window_manager.dart';
import '../../domain/export/conversation_export.dart';
import '../../domain/media/image_codec_util.dart';
import '../../domain/memory/memory_candidate_service.dart';
import '../../domain/memory/memory_entry.dart';
import '../../domain/memory/memory_safety.dart';
import '../../domain/speech/mimo_speech_input_service.dart';
import '../../domain/speech/speech_input_service.dart';
import '../../domain/speech/text_to_speech_service.dart';
import '../../domain/story/story_length_budget.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/tools/file_parser.dart';
import '../../domain/tools/local_file_reader.dart';
import '../../state/character_controller.dart';
import '../../state/chat_controller.dart';
import '../../state/memory_controller.dart';
import '../../state/settings_controller.dart';
import '../shell/shell_tab.dart';
import '../memory/memory_candidate_review_sheet.dart';
import '../story/director_story_setup_page.dart';
import '../story/ensemble_setup_page.dart';
import '../story/story_panel.dart';
import '../study/study_session_actions.dart';
import 'jump_to_message.dart';
import 'widgets/attachment_chip.dart';
import 'widgets/conversation_outline_panel.dart';
import 'widgets/image_pick_confirm_bar.dart';
import 'widgets/library_picker_sheet.dart';
import 'widgets/message_bubble.dart';
import 'widgets/recent_photo_sheet.dart';

class _FileIngestSource {
  const _FileIngestSource({
    required this.name,
    this.extension,
    this.path,
    this.bytes,
    this.reportedSize,
    this.stream,
  });

  final String name;
  final String? extension;
  final String? path;
  final Uint8List? bytes;
  final int? reportedSize;
  final Stream<List<int>>? stream;
}

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
  late final SpeechInputService _systemSpeechInput;
  MimoSpeechInputService? _mimoSpeechInput;
  bool _usingMimoAsr = false;
  late final TextToSpeechService _textToSpeech;
  late TextToSpeechPlayback _ttsPlayback;
  bool _picking = false;
  bool _imageMode = false;
  bool _longTaskMode = false;

  /// After system image pick: confirm strip (scroll + checkbox) before attach.
  List<PendingImagePick>? _pendingImagePicks;
  bool _pendingImageForGen = false;
  int _pendingImageMaxSlots = 1;
  bool _speechBusy = false;
  bool _speechListening = false;
  bool _speechReceivedText = false;
  bool _speechFailureReported = false;
  int _speechSession = 0;
  String _speechBefore = '';
  String _speechAfter = '';
  int _shownTtsErrorRequest = -1;
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
  static const int _maxAttachments = 8;
  static const int _maxAttachmentBytes = 10 * 1024 * 1024;
  static const int _maxTotalAttachmentBytes = 48 * 1024 * 1024;

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
    _systemSpeechInput = ref.read(speechInputServiceProvider);
    _textToSpeech = ref.read(textToSpeechServiceProvider);
    _ttsPlayback = _textToSpeech.playback.value;
    _textToSpeech.playback.addListener(_handleTextToSpeechPlayback);
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
    _speechSession++;
    _systemSpeechInput.detach();
    unawaited(_systemSpeechInput.cancel());
    _mimoSpeechInput?.detach();
    final mimoSpeechInput = _mimoSpeechInput;
    if (mimoSpeechInput != null) unawaited(mimoSpeechInput.cancel());
    _textToSpeech.playback.removeListener(_handleTextToSpeechPlayback);
    unawaited(_textToSpeech.stop());
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission sheets temporarily make Android/iOS inactive. Keep the
    // first-tap initialization alive; a real background transition will
    // continue to paused/hidden and be cancelled below.
    if (state == AppLifecycleState.inactive &&
        _speechBusy &&
        !_speechListening) {
      return;
    }
    if (state != AppLifecycleState.resumed) {
      unawaited(_cancelSpeech());
      unawaited(_textToSpeech.stop());
    }
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
  ) async {
    if (_ttsPlayback.isFor(message.id) && _ttsPlayback.isActive) {
      await _textToSpeech.stop();
      return;
    }

    // Never let speaker output feed back into the microphone recognizer.
    if (_speechListening || _speechBusy) await _cancelSpeech();
    if (!mounted) return;

    final ui = settings?.ui ?? const UiPrefs();
    await _textToSpeech.speak(
      TextToSpeechRequest(
        messageId: message.id,
        text: message.content,
        rate: ui.ttsSpeed.speechRate,
        autoEmotion: ui.ttsAutoEmotion,
        apiConfig: settings?.ttsApi,
        apiKey: settings?.ttsApiKey ?? '',
      ),
    );
  }

  void _handleTextToSpeechPlayback() {
    if (!mounted) return;
    final next = _textToSpeech.playback.value;
    final error = next.errorMessage;
    final showError = error != null && _shownTtsErrorRequest != next.requestId;
    if (showError) _shownTtsErrorRequest = next.requestId;

    setState(() => _ttsPlayback = next);
    if (!showError) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showSpeechNotice(error);
    });
  }

  Future<void> _toggleSpeech() async {
    if (_speechBusy) {
      // A second tap during MiMo upload is an explicit cancellation request.
      if (_usingMimoAsr) await _cancelSpeech();
      return;
    }
    if (_speechListening) {
      if (_usingMimoAsr) {
        await _finishMimoSpeech();
      } else {
        await _cancelSpeech();
      }
      return;
    }

    await _textToSpeech.stop();
    if (!mounted) return;

    final settings = ref.read(settingsControllerProvider).value;
    final useMimoAsr = settings?.asrConfigured ?? false;
    final session = ++_speechSession;
    _speechFailureReported = false;
    _usingMimoAsr = useMimoAsr;
    setState(() => _speechBusy = true);
    final availability = useMimoAsr
        ? await _mimoService.initialize(
            onStatus: (status) => _handleSpeechStatus(session, status),
            onError: (failure) => _handleSpeechError(session, failure),
          )
        : await _systemSpeechInput.initialize(
            onStatus: (status) => _handleSpeechStatus(session, status),
            onError: (failure) => _handleSpeechError(session, failure),
          );
    if (!mounted || session != _speechSession) return;

    if (availability != SpeechInputAvailability.ready) {
      setState(() => _speechBusy = false);
      _showSpeechNotice(
        availability == SpeechInputAvailability.permissionDenied
            ? '未获得麦克风或语音识别权限，请在系统设置中允许后重试。'
            : useMimoAsr
            ? '当前设备无法录制音频，请检查麦克风是否可用。'
            : '当前设备没有可用的系统语音识别服务。',
      );
      return;
    }

    final text = _input.text;
    final selection = _input.selection;
    final selectionValid =
        selection.isValid &&
        selection.start >= 0 &&
        selection.end <= text.length;
    final start = selectionValid ? selection.start : text.length;
    final end = selectionValid ? selection.end : text.length;
    _speechBefore = text.substring(0, start);
    _speechAfter = text.substring(end);
    _speechReceivedText = false;

    final started = useMimoAsr
        ? await _mimoService.start(
            config: settings!.asrApi,
            apiKey: settings.asrApiKey,
            onResult: (result) => _handleSpeechResult(session, result),
          )
        : await _systemSpeechInput.start(
            onResult: (result) => _handleSpeechResult(session, result),
          );
    if (!mounted || session != _speechSession) {
      if (started) unawaited(_cancelSpeechInput(useMimoAsr));
      return;
    }
    setState(() {
      _speechBusy = false;
      _speechListening = started;
    });
    if (!started) {
      // Ensure no orphan microphone session if status never flipped active.
      unawaited(_cancelSpeechInput(useMimoAsr));
      if (!_speechFailureReported) {
        _showSpeechNotice(
          useMimoAsr
              ? '未能启动录音，请检查麦克风权限后重试。'
              : defaultTargetPlatform == TargetPlatform.windows
              ? '未能启动语音识别。请检查麦克风权限，并在系统设置中安装中文语音包。'
              : '未能启动系统语音识别，请稍后再试。',
        );
      }
    } else if (useMimoAsr && mounted) {
      // Cloud ASR has no partials; make the second-tap finish step obvious.
      _showSpeechNotice('已开始录音。说完后再次点击麦克风即可识别。');
    }
  }

  MimoSpeechInputService get _mimoService {
    final existing = _mimoSpeechInput;
    if (existing != null) return existing;
    final created = ref.read(mimoSpeechInputServiceProvider);
    _mimoSpeechInput = created;
    return created;
  }

  Future<void> _finishMimoSpeech() async {
    if (!_speechListening || !_usingMimoAsr) return;
    final settings = ref.read(settingsControllerProvider).value;
    if (settings == null || !settings.asrConfigured) {
      await _cancelSpeech();
      _showSpeechNotice('MiMo 云端语音识别配置已变更，请重新开始录音。');
      return;
    }
    final session = _speechSession;
    setState(() {
      _speechListening = false;
      _speechBusy = true;
    });
    await _mimoService.finish(
      config: settings.asrApi,
      apiKey: settings.asrApiKey,
    );
    if (!mounted || session != _speechSession) return;
    // The service normally sends a final result or a stopped status. This
    // fallback prevents a broken recorder implementation from leaving the
    // composer in a perpetual loading state.
    if (_speechBusy) setState(() => _speechBusy = false);
  }

  void _handleSpeechResult(int session, SpeechInputResult result) {
    if (!mounted || session != _speechSession) return;
    final spoken = result.text.trim();
    if (spoken.isNotEmpty) {
      _speechReceivedText = true;
      if (_usingMimoAsr) {
        // The composer stays editable while the MiMo upload is in flight, so
        // the snapshot taken at recording start may be stale. Insert at the
        // live cursor position instead of rebuilding from the old snapshot,
        // which would discard anything typed during the upload.
        final current = _input.value;
        final text = current.text;
        final selection = current.selection;
        final valid =
            selection.isValid &&
            selection.start >= 0 &&
            selection.end <= text.length;
        final start = valid ? selection.start : text.length;
        final end = valid ? selection.end : start;
        final before = text.substring(0, start);
        final after = text.substring(end);
        _input.value = TextEditingValue(
          text: mergeSpeechIntoDraft(
            before: before,
            transcript: spoken,
            after: after,
          ),
          selection: TextSelection.collapsed(
            offset: mergeSpeechIntoDraft(
              before: before,
              transcript: spoken,
              after: '',
            ).length,
          ),
        );
      } else {
        final merged = mergeSpeechIntoDraft(
          before: _speechBefore,
          transcript: spoken,
          after: _speechAfter,
        );
        _input.value = TextEditingValue(
          text: merged,
          selection: TextSelection.collapsed(
            offset: mergeSpeechIntoDraft(
              before: _speechBefore,
              transcript: spoken,
              after: '',
            ).length,
          ),
        );
      }
    }
    // Cloud ASR emits a single final transcript after upload — that ends the
    // session. System dictation emits one finalResult per phrase while the
    // platform session is still open (pauseFor/listenFor); treating those as
    // session-end hid the listening indicator and left the mic orphaned.
    if (result.isFinal && _usingMimoAsr && (_speechListening || _speechBusy)) {
      setState(() {
        _speechListening = false;
        _speechBusy = false;
      });
    }
  }

  void _handleSpeechStatus(int session, SpeechInputStatus status) {
    if (!mounted || session != _speechSession) return;
    final listening = status == SpeechInputStatus.listening;
    if (_speechListening == listening && !_speechBusy) return;
    setState(() {
      _speechListening = listening;
      _speechBusy = false;
    });
  }

  void _handleSpeechError(int session, SpeechInputFailure failure) {
    if (!mounted || session != _speechSession) return;
    _speechFailureReported = true;
    final code = failure.code.toLowerCase();
    final wasActive = _speechListening || _speechBusy;
    final quietTimeout =
        _speechReceivedText &&
        (code.contains('no_match') || code.contains('speech_timeout'));
    if (wasActive) {
      setState(() {
        _speechListening = false;
        _speechBusy = false;
      });
    }
    // Some platforms keep the recognizer alive after a non-permanent error.
    // Always terminate it here so a hidden microphone cannot outlive the UI.
    if (wasActive) unawaited(_cancelSpeechInput(_usingMimoAsr));
    if (!quietTimeout) _showSpeechNotice(failure.userMessage);
  }

  Future<void> _cancelSpeech() async {
    final wasActive = _speechListening || _speechBusy;
    final useMimoAsr = _usingMimoAsr;
    ++_speechSession;
    if (mounted && wasActive) {
      setState(() {
        _speechListening = false;
        _speechBusy = false;
      });
    }
    if (wasActive) await _cancelSpeechInput(useMimoAsr);
  }

  Future<void> _cancelSpeechInput(bool useMimoAsr) async {
    if (useMimoAsr) {
      await _mimoSpeechInput?.cancel();
    } else {
      await _systemSpeechInput.cancel();
    }
  }

  void _showSpeechNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _send({bool forceDocumentEdit = false}) async {
    if (_speechListening || _speechBusy) await _cancelSpeech();
    if (_pendingImagePicks != null) {
      _showAttachmentNotice('请先确认或取消待添加的图片');
      return;
    }
    final text = _input.text;
    final settings = ref.read(settingsControllerProvider).value;
    if (forceDocumentEdit) {
      if (settings == null || !settings.supportsDocumentEdit) {
        _showAttachmentNotice('请先在设置中连接并发现支持文档编辑的 MCP Tools');
        return;
      }
      if (!_attachments.any((a) => a.isEditableDocument)) {
        _showAttachmentNotice(
          '请先上传可编辑的 .xlsx / .docx / .pptx / .txt / .md / .csv / .tsv',
        );
        return;
      }
      if (_imageMode) {
        _showAttachmentNotice('请先退出生图模式再改文档');
        return;
      }
    } else if (text.trim().isEmpty && _attachments.isEmpty) {
      return;
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
            : '当前 MCP Server 未提供文件长任务；该能力仅在旧 Gateway 部署中可用。',
      );
      return;
    }
    if (useImageGeneration) {
      if (text.trim().isEmpty) {
        _showAttachmentNotice(
          _attachments.any((a) => a.isImage) ? '图生图请写明如何修改参考图。' : '请描述要生成的图片。',
        );
        return;
      }
      final nonImages = _attachments.where((a) => !a.isImage).toList();
      if (nonImages.isNotEmpty) {
        _showAttachmentNotice('生图模式仅支持图片参考，请移除非图片附件。');
        return;
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
    if (!accepted && mounted && _input.text.isEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
      setState(() {
        _attachments.addAll(attachments);
        _longTaskMode = useLongTask;
      });
    }
  }

  static bool attachmentsAreDocuments(List<Attachment> attachments) =>
      attachments.isNotEmpty && attachments.every((a) => !a.isImage);

  static const _documentExtensions = [
    'pdf',
    'docx',
    'xlsx',
    'pptx',
    'txt',
    'md',
    'csv',
    'tsv',
    'json',
  ];
  static const _imageExtensions = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'];

  Future<void> _pickDocuments() => _pickFiles(imagesOnly: false);

  Future<void> _pickImages() => _pickFiles(
    imagesOnly: true,
    // 生图模式：参考图不依赖视觉 API；普通对话看图需要视觉模型或独立视觉 API。
    forImageGeneration: _imageMode,
  );

  Future<void> _openLibraryPicker() async {
    if (_picking) return;
    final forImageGeneration = _imageMode;
    final imagesOnly = _imageMode;
    final maxSlots = _slotCap(
      forImageGeneration: forImageGeneration,
      imagesOnly: imagesOnly,
    );
    final remaining = forImageGeneration && imagesOnly
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
    final picked = await showLibraryPicker(
      context,
      repository: ref.read(libraryRepositoryProvider),
      maxCount: remaining,
      kind: imagesOnly ? LibraryItemKind.image : null,
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    if (imagesOnly) {
      _attachImagesDirectly(
        picked,
        forImageGeneration: forImageGeneration,
        maxSlots: remaining,
      );
    } else {
      setState(() => _attachments.addAll(picked.take(remaining)));
    }
  }

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

  Future<void> _pickFiles({
    required bool imagesOnly,
    bool forImageGeneration = false,
  }) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final settings = ref.read(settingsControllerProvider).value;
      final visionOk =
          settings?.canAttachImages(
            deepThink:
                ref.read(chatControllerProvider).value?.deepThink ?? false,
          ) ??
          false;
      final imageGenOk = settings?.imageGenerationConfigured ?? false;
      if (imagesOnly && forImageGeneration) {
        if (!imageGenOk) {
          _showAttachmentNotice('请先在设置中配置图片生成 API。');
          return;
        }
      } else if (imagesOnly && !visionOk) {
        _showAttachmentNotice(
          '当前模型不支持看图。请选用视觉模型（如 ${KnownModels.vision}），'
          '或在设置中配置独立视觉 API。',
        );
        return;
      }
      // 图生图：gpt-image-* 可多参考；其它 edits 网关仍 1 张。
      final maxSlots = _slotCap(
        forImageGeneration: forImageGeneration,
        imagesOnly: imagesOnly,
      );

      // Mobile: recent album sheet first; desktop / web keep system picker.
      if (imagesOnly && supportsRecentPhotoSheet && mounted) {
        final remaining = forImageGeneration
            ? (maxSlots - _attachments.where((a) => a.isImage).length).clamp(
                0,
                maxSlots,
              )
            : _maxAttachments - _attachments.length;
        if (remaining <= 0) {
          _showAttachmentNotice(
            forImageGeneration
                ? (maxSlots <= 1
                      ? '图生图每次仅支持 1 张参考图，请先移除当前图片。'
                      : '图生图最多 $maxSlots 张参考图，请先移除部分图片。')
                : '最多可添加 $_maxAttachments 个附件。',
          );
          return;
        }
        final album = await showRecentPhotoPicker(context, maxCount: remaining);
        if (!mounted) return;
        if (album == null) return;
        if (!album.fromFiles) {
          await _ingestAlbumAssets(
            album.assets,
            forImageGeneration: forImageGeneration,
            maxSlots: remaining,
          );
          return;
        }
        // fromFiles → fall through to FilePicker below.
      }

      final result = await FilePicker.pickFiles(
        allowMultiple: !(forImageGeneration && imagesOnly && maxSlots <= 1),
        withData: false,
        withReadStream: true,
        type: FileType.custom,
        allowedExtensions: imagesOnly
            ? _imageExtensions
            : [..._documentExtensions, if (visionOk) ..._imageExtensions],
      );
      if (result == null) return;

      final slots = forImageGeneration && imagesOnly
          ? (maxSlots - _attachments.where((a) => a.isImage).length).clamp(
              0,
              maxSlots,
            )
          : _maxAttachments - _attachments.length;
      if (slots <= 0) {
        _showAttachmentNotice(
          forImageGeneration && imagesOnly
              ? (maxSlots <= 1
                    ? '图生图每次仅支持 1 张参考图，请先移除当前图片。'
                    : '图生图最多 $maxSlots 张参考图，请先移除部分图片。')
              : '最多可添加 $_maxAttachments 个附件。',
        );
        return;
      }

      await _ingestFileSources(
        [
          for (final f in result.files)
            _FileIngestSource(
              name: f.name,
              extension: f.extension,
              path: f.path,
              reportedSize: f.size,
              stream: f.readStream,
            ),
        ],
        imagesOnly: imagesOnly,
        forImageGeneration: forImageGeneration,
        confirmImages: true,
        slots: slots,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _handleComposerPaste() async {
    if (_picking || _speechListening) return;
    final streaming =
        ref.read(chatControllerProvider).value?.isStreaming ?? false;
    if (streaming) {
      await _pasteTextIntoComposer();
      return;
    }

    ClipboardMedia media = const ClipboardMedia();
    try {
      media = await readClipboardMedia();
    } catch (_) {}
    if (!mounted) return;
    if (!media.hasAttachable) {
      await _pasteTextIntoComposer();
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

    final sources = <_FileIngestSource>[
      for (final path in media.filePaths)
        _FileIngestSource(
          name: fileNameFromPath(path),
          extension: extensionOfName(fileNameFromPath(path)),
          path: path,
        ),
    ];
    if (sources.isEmpty && media.hasImage) {
      final identity = clipboardImageIdentity(media.imageBytes!);
      sources.add(
        _FileIngestSource(
          name: identity.name,
          extension: identity.extension,
          bytes: media.imageBytes,
          reportedSize: media.imageBytes!.lengthInBytes,
        ),
      );
    }
    if (sources.isEmpty) {
      await _pasteTextIntoComposer();
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

    if (_picking) return;
    setState(() => _picking = true);
    try {
      final imagesOnly = usable.every((s) => imageExts.contains(s.extension));
      await _ingestFileSources(
        usable,
        imagesOnly: imagesOnly,
        forImageGeneration: forImageGeneration,
        confirmImages: false,
        extraNotice: skippedUnsupported > 0
            ? '跳过 $skippedUnsupported 个不支持的文件'
            : null,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pasteTextIntoComposer() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
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
    List<_FileIngestSource> sources, {
    required bool imagesOnly,
    bool forImageGeneration = false,
    bool confirmImages = true,
    int? slots,
    String? extraNotice,
  }) async {
    if (sources.isEmpty) return;
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
    for (final source in sources) {
      if (additions.length >= remaining) {
        tooMany++;
        continue;
      }
      final reported = source.reportedSize ?? 0;
      if (reported > _maxAttachmentBytes) {
        tooLarge++;
        continue;
      }
      final Uint8List bytes;
      if (source.bytes != null) {
        bytes = source.bytes!;
      } else {
        final stream = source.stream ?? openLocalFileReadStream(source.path);
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
      }
      final sizeBytes = reported > bytes.lengthInBytes
          ? reported
          : bytes.lengthInBytes;
      if (sizeBytes > _maxAttachmentBytes) {
        tooLarge++;
        continue;
      }
      if (runningTotal + sizeBytes > _maxTotalAttachmentBytes) {
        overTotal++;
        continue;
      }
      final mimeType = _mimeFor(source.extension);
      final Attachment attachment;
      final int attachedSize;
      if (mimeType.startsWith('image/')) {
        final built = await _buildImageAttachment(
          name: source.name,
          mimeType: mimeType,
          sizeBytes: sizeBytes,
          bytes: bytes,
        );
        attachment = built;
        attachedSize = built.sizeBytes;
      } else {
        attachment = await parser.parseAsync(
          name: source.name,
          mimeType: mimeType,
          sizeBytes: sizeBytes,
          bytes: bytes,
        );
        attachedSize = sizeBytes;
      }
      if (!mounted) return;
      additions.add(attachment);
      runningTotal += attachedSize;
    }
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

  /// Turn album [AssetEntity]s into the same pending confirm strip as file pick.
  Future<void> _ingestAlbumAssets(
    List<AssetEntity> assets, {
    required bool forImageGeneration,
    required int maxSlots,
  }) async {
    final additions = <Attachment>[];
    var runningTotal = _attachments.fold<int>(
      0,
      (total, attachment) => total + attachment.sizeBytes,
    );
    var tooLarge = 0;
    var unreadable = 0;
    for (final asset in assets) {
      if (additions.length >= maxSlots) break;
      try {
        final bytes = await loadAssetImageBytes(asset);
        if (bytes == null || bytes.isEmpty) {
          unreadable++;
          continue;
        }
        if (bytes.lengthInBytes > _maxAttachmentBytes) {
          tooLarge++;
          continue;
        }
        if (runningTotal + bytes.lengthInBytes > _maxTotalAttachmentBytes) {
          tooLarge++;
          continue;
        }
        final title = asset.title?.trim();
        final name = (title == null || title.isEmpty)
            ? 'photo_${DateTime.now().microsecondsSinceEpoch}.jpg'
            : (title.contains('.') ? title : '$title.jpg');
        final built = await _buildImageAttachment(
          name: name,
          mimeType: 'image/jpeg',
          sizeBytes: bytes.lengthInBytes,
          bytes: bytes,
        );
        if (built.parseError != null || !built.hasImageData) {
          unreadable++;
          continue;
        }
        additions.add(built);
        runningTotal += built.sizeBytes;
      } catch (_) {
        unreadable++;
      }
    }
    if (!mounted) return;
    final notices = <String>[];
    if (tooLarge > 0) notices.add('跳过 $tooLarge 个（过大）');
    if (unreadable > 0) notices.add('跳过 $unreadable 个（无法读取）');
    if (additions.isEmpty) {
      notices.add('没有可用的图片');
      if (notices.isNotEmpty) _showAttachmentNotice(notices.join('；'));
      return;
    }
    setState(() {
      _pendingImageForGen = forImageGeneration;
      _pendingImageMaxSlots = maxSlots;
      _pendingImagePicks = [
        for (var i = 0; i < additions.length; i++)
          PendingImagePick(
            attachment: additions[i],
            selected: maxSlots <= 1 ? i == 0 : i < maxSlots,
          ),
      ];
    });
    if (notices.isNotEmpty) _showAttachmentNotice(notices.join('；'));
  }

  /// Build an image [Attachment] with the bytes pre-scaled to ≤1536px on the
  /// long edge. Mirrors [FileParser.maxImageBytes] so an oversized image
  /// surfaces a parse error instead of stalling the decode.
  Future<Attachment> _buildImageAttachment({
    required String name,
    required String mimeType,
    required int sizeBytes,
    required Uint8List bytes,
  }) async {
    if (bytes.lengthInBytes > FileParser.maxImageBytes) {
      return Attachment(
        name: name,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        parseError: '图片过大（超过 5MB），未附加。',
      );
    }
    final prepared = await ImageCodecUtil.prepareReferenceImage(
      bytes,
      mimeType: mimeType,
      name: name,
    );
    return Attachment(
      name: prepared.name,
      mimeType: prepared.mimeType,
      sizeBytes: prepared.bytes.lengthInBytes,
      imageBase64: base64Encode(prepared.bytes),
    );
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
    'tsv' => 'text/tab-separated-values',
    'json' => 'application/json',
    'md' => 'text/markdown',
    'txt' => 'text/plain',
    _ => 'text/plain',
  };

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

  void _toggleImageMode() {
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
                labelText: '保存为长期记忆',
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
            existingMemories: existing.entries,
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
        unawaited(_cancelSpeech());
        _stick = true;
        _messageKeys.clear();
        if (_selecting) {
          _selecting = false;
          _selectedIds.clear();
        }
        // Do not carry composer draft / reference images across conversations.
        if (_attachments.isNotEmpty ||
            _input.text.isNotEmpty ||
            _imageMode ||
            _pendingImagePicks != null) {
          setState(() {
            _attachments.clear();
            _input.clear();
            _imageMode = false;
            _longTaskMode = false;
            _pendingImagePicks = null;
            _pendingImageForGen = false;
          });
        }
      }
      _scrollToBottom();
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
                titleSpacing: dualPane ? 20 : 8,
                title: LayoutBuilder(
                  builder: (context, constraints) {
                    return SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight.isFinite
                          ? constraints.maxHeight
                          : 56,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Row(
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        titleText,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (slice.hasCurrent && storyLike)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2,
                                          ),
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
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                ),
                                              ],
                                              if (storyLike) ...[
                                                const SizedBox(width: 6),
                                                GestureDetector(
                                                  onTap: () {
                                                    final convo = ref
                                                        .read(
                                                          chatControllerProvider,
                                                        )
                                                        .value
                                                        ?.current;
                                                    if (convo != null) {
                                                      _openPlot(
                                                        convo,
                                                        canPinTools: triplePane,
                                                      );
                                                    }
                                                  },
                                                  child: Text(
                                                    '情节',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .labelSmall
                                                        ?.copyWith(
                                                          color: modeColor,
                                                          fontWeight:
                                                              FontWeight.w700,
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
                          ),
                          if (showWorkMode)
                            _ComposerWorkModeSwitch(
                              workMode: slice.workMode,
                              onChanged: controller.setWorkMode,
                            ),
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
                        child: _ContextUsageChip(
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
                        ? Center(child: Text('出错了：${slice.loadError}'))
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
        showError && slice.error != null && slice.error!.contains('API Key');
    final settings = ref.watch(settingsControllerProvider).value;
    final ui = settings?.ui ?? const UiPrefs();
    return Column(
      children: [
        if (showError && slice.error != null)
          _ErrorBanner(
            message: slice.error!,
            onRetry:
                slice.isStreaming ||
                    slice.retryConversationId == null ||
                    slice.retryConversationId != slice.currentId
                ? null
                : () => controller.retryLast(),
            onOpenSettings: needsSetup
                ? () => openShellTab(ref, ShellTab.settings)
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
        if (!_selecting)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.55,
            ),
            child: CustomScrollView(
              shrinkWrap: true,
              slivers: [
                SliverToBoxAdapter(
                  child: _Composer(
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
                    speechBusy: _speechBusy,
                    speechListening: _speechListening,
                    speechUsesCloudAsr: _usingMimoAsr,
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
                    onToggleImageGenMode: controller.toggleImageGenMode,
                    onToggleImageMode: _toggleImageMode,
                    onToggleLongTask: () =>
                        setState(() => _longTaskMode = !_longTaskMode),
                    onPickDocuments: _pickDocuments,
                    onPickImages: _pickImages,
                    onPickLibrary: _openLibraryPicker,
                    onPaste: _handleComposerPaste,
                    onRemoveAttachment: _removeAttachment,
                    onToggleSpeech: _toggleSpeech,
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
    if (messages.isEmpty) return const _EmptyState();
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
                final ttsForMessage = _ttsPlayback.isFor(m.id);
                return KeyedSubtree(
                  key: _keyForMessage(m.id),
                  child: MessageBubble(
                    key: ValueKey(m.id),
                    message: m,
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
                        _ttsPlayback.phase == TextToSpeechPhase.loading,
                    isSpeaking:
                        ttsForMessage &&
                        _ttsPlayback.phase == TextToSpeechPhase.speaking,
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

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.isStreaming,
    required this.deepThink,
    this.reasoningEffort = ReasoningEffort.high,
    this.supportsReasoningEffort = false,
    required this.searchMode,
    required this.imageGenMode,
    required this.attachments,
    required this.picking,
    required this.storyLike,
    this.isStudy = false,
    required this.directorMode,
    required this.canAttachImages,
    required this.imageGenerationConfigured,
    required this.imageMode,
    required this.longTaskMode,
    required this.longTaskAvailable,
    this.maxImageEditReferences = 1,
    this.documentEditAvailable = false,
    required this.speechBusy,
    required this.speechListening,
    required this.speechUsesCloudAsr,
    required this.onToggleDeepThink,
    this.onReasoningEffortChanged,
    required this.onToggleSearch,
    this.mcpAvailable = false,
    this.mcpSelectedCount = 0,
    this.onPickMcpServers,
    required this.onToggleImageGenMode,
    required this.onToggleImageMode,
    required this.onToggleLongTask,
    required this.onPickDocuments,
    required this.onPickImages,
    required this.onPickLibrary,
    required this.onPaste,
    required this.onRemoveAttachment,
    required this.onToggleSpeech,
    required this.onSend,
    this.onDocumentEdit,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool isStreaming;
  final bool deepThink;
  final ReasoningEffort reasoningEffort;
  final bool supportsReasoningEffort;
  final SearchMode searchMode;
  final ImageGenMode imageGenMode;
  final List<Attachment> attachments;
  final bool picking;
  final bool storyLike;
  final bool isStudy;
  final bool directorMode;
  final bool canAttachImages;
  final bool imageGenerationConfigured;
  final bool imageMode;
  final bool longTaskMode;
  final bool longTaskAvailable;
  final int maxImageEditReferences;
  final bool documentEditAvailable;
  final bool speechBusy;
  final bool speechListening;
  final bool speechUsesCloudAsr;
  final VoidCallback onToggleDeepThink;
  final ValueChanged<ReasoningEffort>? onReasoningEffortChanged;
  final VoidCallback onToggleSearch;
  final bool mcpAvailable;
  final int mcpSelectedCount;
  final VoidCallback? onPickMcpServers;
  final VoidCallback onToggleImageGenMode;
  final VoidCallback onToggleImageMode;
  final VoidCallback onToggleLongTask;
  final VoidCallback onPickDocuments;
  final VoidCallback onPickImages;
  final VoidCallback onPickLibrary;
  final Future<void> Function() onPaste;
  final ValueChanged<String> onRemoveAttachment;
  final VoidCallback onToggleSpeech;
  final VoidCallback onSend;
  final VoidCallback? onDocumentEdit;
  final VoidCallback onStop;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  /// DeepSeek-style expandable “+” tray for upload / image actions.
  bool _plusOpen = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _focusNode.dispose();
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_focusNode.hasFocus) return false;
    if (widget.controller.value.composing.isValid) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyV) return false;
    if (HardwareKeyboard.instance.isAltPressed) return false;
    if (!HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      return false;
    }
    widget.onPaste();
    return true;
  }

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
        ? (widget.attachments.any((a) => a.isImage)
              ? '描述如何修改参考图（图生图）…'
              : '描述要生成的图片；可点 + 上传参考图…')
        : widget.directorMode
        ? '发导演指令，或使用“写下一场 / 续写当前场”…'
        : widget.storyLike
        ? '续写反应，或输入旁白…'
        : '写下你的想法…';
    final canAttachDocs =
        !widget.isStreaming && !widget.picking && !widget.imageMode;
    final canAttachImages =
        !widget.isStreaming &&
        !widget.picking &&
        ((widget.imageMode && widget.imageGenerationConfigured) ||
            (!widget.imageMode && widget.canAttachImages));
    return Container(
      key: const ValueKey('chat-composer'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface.withValues(alpha: 0),
            scheme.surface.withValues(alpha: 0.94),
            scheme.surface,
          ],
          stops: const [0, 0.32, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, compactHeight ? 8 : 13),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 深度思考 stays on the strip. 对话|任务 lives in the top bar.
                  // Tool toggles live in the “+” tray.
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _ComposerToggleChip(
                          selected: widget.deepThink,
                          icon: Icons.psychology_outlined,
                          label: '深度思考',
                          onSelected: widget.onToggleDeepThink,
                        ),
                        if (widget.deepThink &&
                            widget.supportsReasoningEffort) ...[
                          const SizedBox(width: 8),
                          _ReasoningEffortSlider(
                            value: widget.reasoningEffort,
                            onChanged: widget.onReasoningEffortChanged,
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
                              imageGenerationConfigured:
                                  widget.imageGenerationConfigured,
                              imageMode: widget.imageMode,
                              picking: widget.picking,
                              searchMode: widget.searchMode,
                              imageGenMode: widget.imageGenMode,
                              mcpAvailable: widget.mcpAvailable,
                              mcpSelectedCount: widget.mcpSelectedCount,
                              documentEditAvailable:
                                  widget.documentEditAvailable &&
                                  !widget.isStreaming,
                              longTaskAvailable: widget.longTaskAvailable,
                              longTaskMode: widget.longTaskMode,
                              onPickDocuments: canAttachDocs
                                  ? () => _runAndClose(widget.onPickDocuments)
                                  : null,
                              onPickImages: canAttachImages
                                  ? () => _runAndClose(widget.onPickImages)
                                  : null,
                              onPickLibrary: widget.isStreaming
                                  ? null
                                  : () => _runAndClose(widget.onPickLibrary),
                              onToggleImageMode: widget.isStreaming
                                  ? null
                                  : () =>
                                        _runAndClose(widget.onToggleImageMode),
                              onToggleSearch: widget.storyLike || widget.isStudy
                                  ? null
                                  : widget.onToggleSearch,
                              onToggleImageGenMode:
                                  widget.imageGenerationConfigured &&
                                      !widget.imageMode &&
                                      !widget.isStudy
                                  ? widget.onToggleImageGenMode
                                  : null,
                              onPickMcpServers: widget.mcpAvailable
                                  ? () => _runAndClose(
                                      widget.onPickMcpServers ?? () {},
                                    )
                                  : null,
                              onDocumentEdit: widget.documentEditAvailable
                                  ? () => _runAndClose(
                                      widget.onDocumentEdit ?? () {},
                                    )
                                  : null,
                              onToggleLongTask: widget.longTaskAvailable
                                  ? widget.onToggleLongTask
                                  : null,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.72),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.08),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
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
                        if (widget.speechListening)
                          Padding(
                            key: const ValueKey('speech-listening-indicator'),
                            padding: const EdgeInsets.fromLTRB(8, 3, 8, 1),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 16,
                                  color: scheme.error,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    // Cloud ASR only transcribes after a second
                                    // mic tap; system ASR streams partial text.
                                    widget.speechUsesCloudAsr
                                        ? '正在录音… 说完后再点麦克风识别（不会自动发送）'
                                        : '正在听… 识别文字不会自动发送',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                              ],
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
                                        !widget.speechBusy &&
                                        !widget.speechListening &&
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
                                  key: const ValueKey('composer-text-field'),
                                  controller: widget.controller,
                                  focusNode: _focusNode,
                                  minLines: 1,
                                  maxLines: compactHeight ? 3 : 5,
                                  readOnly: widget.speechListening,
                                  textInputAction: TextInputAction.newline,
                                  onTap: _closePlus,
                                  contextMenuBuilder: (context, editableTextState) {
                                    return AdaptiveTextSelectionToolbar.buttonItems(
                                      anchors:
                                          editableTextState.contextMenuAnchors,
                                      buttonItems: [
                                        for (final item
                                            in editableTextState
                                                .contextMenuButtonItems)
                                          if (item.type ==
                                              ContextMenuButtonType.paste)
                                            ContextMenuButtonItem(
                                              onPressed: () {
                                                editableTextState.hideToolbar();
                                                widget.onPaste();
                                              },
                                              type: ContextMenuButtonType.paste,
                                            )
                                          else
                                            item,
                                      ],
                                    );
                                  },
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
                            IconButton.filledTonal(
                              key: const ValueKey('composer-microphone-button'),
                              onPressed:
                                  widget.isStreaming ||
                                      (widget.speechBusy &&
                                          !widget.speechUsesCloudAsr)
                                  ? null
                                  : () {
                                      _closePlus();
                                      widget.onToggleSpeech();
                                    },
                              icon: widget.speechBusy
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      widget.speechListening
                                          ? Icons.mic_rounded
                                          : Icons.mic_none_rounded,
                                    ),
                              tooltip: widget.speechBusy
                                  ? widget.speechUsesCloudAsr
                                        ? '正在上传语音；点按取消'
                                        : '正在准备语音输入'
                                  : widget.speechListening
                                  ? widget.speechUsesCloudAsr
                                        ? '结束录音并识别'
                                        : '停止语音输入'
                                  : '语音输入',
                              style: IconButton.styleFrom(
                                fixedSize: const Size.square(40),
                                backgroundColor: widget.speechListening
                                    ? scheme.errorContainer
                                    : scheme.secondaryContainer,
                                foregroundColor: widget.speechListening
                                    ? scheme.onErrorContainer
                                    : scheme.onSecondaryContainer,
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
        message: open ? '收起' : '添加',
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
    required this.imageGenerationConfigured,
    required this.imageMode,
    required this.picking,
    required this.searchMode,
    required this.imageGenMode,
    required this.mcpAvailable,
    required this.mcpSelectedCount,
    required this.documentEditAvailable,
    required this.longTaskAvailable,
    required this.longTaskMode,
    required this.onPickDocuments,
    required this.onPickImages,
    required this.onPickLibrary,
    required this.onToggleImageMode,
    required this.onToggleSearch,
    required this.onToggleImageGenMode,
    required this.onPickMcpServers,
    required this.onDocumentEdit,
    required this.onToggleLongTask,
  });

  final bool imageGenerationConfigured;
  final bool imageMode;
  final bool picking;
  final SearchMode searchMode;
  final ImageGenMode imageGenMode;
  final bool mcpAvailable;
  final int mcpSelectedCount;
  final bool documentEditAvailable;
  final bool longTaskAvailable;
  final bool longTaskMode;
  final VoidCallback? onPickDocuments;
  final VoidCallback? onPickImages;
  final VoidCallback? onPickLibrary;
  final VoidCallback? onToggleImageMode;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onToggleImageGenMode;
  final VoidCallback? onPickMcpServers;
  final VoidCallback? onDocumentEdit;
  final VoidCallback? onToggleLongTask;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = <Widget>[
      _ComposerPlusAction(
        icon: Icons.folder_open_outlined,
        label: '上传文件',
        enabled: onPickDocuments != null && !picking,
        onTap: onPickDocuments,
      ),
      _ComposerPlusAction(
        icon: Icons.image_outlined,
        label: imageMode ? '参考图' : '上传图片',
        enabled: onPickImages != null && !picking,
        onTap: onPickImages,
      ),
      _ComposerPlusAction(
        icon: Icons.photo_library_outlined,
        label: '素材库',
        enabled: onPickLibrary != null && !picking,
        onTap: onPickLibrary,
      ),
      if (imageGenerationConfigured)
        _ComposerPlusAction(
          icon: imageMode ? Icons.auto_awesome : Icons.auto_awesome_outlined,
          label: imageMode ? '退出生图' : '图片生成',
          selected: imageMode,
          enabled: onToggleImageMode != null,
          onTap: onToggleImageMode,
        ),
      if (onToggleSearch != null)
        _ComposerPlusAction(
          icon: Icons.travel_explore,
          label: searchMode.composerLabel,
          selected: searchMode != SearchMode.off,
          enabled: true,
          onTap: onToggleSearch,
        ),
      if (onToggleImageGenMode != null)
        _ComposerPlusAction(
          icon: Icons.image_outlined,
          label: imageGenMode.composerLabel,
          selected: imageGenMode != ImageGenMode.off,
          enabled: true,
          onTap: onToggleImageGenMode,
        ),
      if (mcpAvailable)
        _ComposerPlusAction(
          icon: Icons.extension_outlined,
          label: mcpSelectedCount == 0 ? 'MCP' : 'MCP·$mcpSelectedCount',
          selected: mcpSelectedCount > 0,
          enabled: onPickMcpServers != null,
          onTap: onPickMcpServers,
        ),
      if (documentEditAvailable)
        _ComposerPlusAction(
          icon: Icons.edit_document,
          label: '改文档',
          enabled: onDocumentEdit != null,
          onTap: onDocumentEdit,
        ),
      if (longTaskAvailable)
        _ComposerPlusAction(
          icon: Icons.schedule_send_outlined,
          label: '长任务',
          selected: longTaskMode,
          enabled: onToggleLongTask != null,
          onTap: onToggleLongTask,
        ),
    ];
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          const columns = 4;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final action in actions)
                SizedBox(width: width, child: action),
            ],
          );
        },
      ),
    );
  }
}

class _ComposerPlusAction extends StatelessWidget {
  const _ComposerPlusAction({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
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
      label: label,
      excludeSemantics: true,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 20, color: fg),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg,
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
    final pct = (fraction * 100).round();
    final color = fraction >= 0.9
        ? scheme.error
        : fraction >= 0.7
        ? scheme.tertiary
        : scheme.primary;

    final detail = report == null
        ? '上下文预算 ${_compactTokens(budget)}（发送后显示本轮用量）'
        : report!.userFacingNote;

    // Compact label for the app bar.
    String label;
    if (report == null) {
      label = _compactTokens(budget);
    } else if (managed) {
      final bits = <String>[
        '$pct%',
        if (report!.droppedMessages > 0) '−${report!.droppedMessages}',
        if (report!.summaryInjected) '摘要',
      ];
      label = bits.join(' · ');
    } else {
      label = '$pct%';
    }

    return Semantics(
      key: const ValueKey('chat-context-usage'),
      label: detail,
      value: '$pct%',
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
            border: managed
                ? Border.all(color: color.withValues(alpha: 0.28))
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  semanticsLabel: detail,
                  semanticsValue: '$pct%',
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

class _ReasoningEffortSlider extends StatelessWidget {
  const _ReasoningEffortSlider({required this.value, this.onChanged});

  final ReasoningEffort value;
  final ValueChanged<ReasoningEffort>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '思考强度 ${value.label}',
      slider: true,
      value: value.label,
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '强度',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              SizedBox(
                width: 108,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    min: 0,
                    max: 2,
                    divisions: 2,
                    value: value.index.toDouble(),
                    label: value.label,
                    onChanged: onChanged == null
                        ? null
                        : (v) => onChanged!(ReasoningEffort.values[v.round()]),
                  ),
                ),
              ),
              Text(
                value.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComposerWorkModeSwitch extends StatelessWidget {
  const _ComposerWorkModeSwitch({required this.workMode, this.onChanged});

  final bool workMode;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('chat-work-mode-switch'),
      label: workMode ? '任务模式' : '对话模式',
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10),
          ),
          textStyle: WidgetStatePropertyAll(
            Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        segments: const [
          ButtonSegment<bool>(value: false, label: Text('对话')),
          ButtonSegment<bool>(value: true, label: Text('任务')),
        ],
        selected: {workMode},
        onSelectionChanged: onChanged == null
            ? null
            : (selection) => onChanged!(selection.first),
        emptySelectionAllowed: false,
      ),
    );
  }
}

class _ComposerToggleChip extends StatelessWidget {
  const _ComposerToggleChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      toggled: selected,
      label: label,
      excludeSemantics: true,
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

/// Unified desktop workspace navigation and conversation history.
///
/// This is public so [AppShell] can own a single left sidebar instead of
/// stacking a navigation rail beside a second history pane.
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

class ChatWorkspaceSidebar extends ConsumerStatefulWidget {
  const ChatWorkspaceSidebar({super.key, this.onCollapse});

  final VoidCallback? onCollapse;

  @override
  ConsumerState<ChatWorkspaceSidebar> createState() =>
      _ChatWorkspaceSidebarState();
}

class _ChatWorkspaceSidebarState extends ConsumerState<ChatWorkspaceSidebar> {
  String _query = '';
  List<SearchHit> _searchHits = const [];

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
      unawaited(_runSearch(value.trim()));
    });
  }

  Future<void> _runSearch(String query) async {
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _query = '';
          _searchHits = const [];
        });
      }
      return;
    }
    final hits = await ref
        .read(conversationRepositoryProvider)
        .searchMessages(query);
    if (!mounted) return;
    setState(() {
      _query = query;
      _searchHits = hits;
    });
  }

  bool _matches(Conversation c, String q) {
    if (_modeFilter != null && c.mode != _modeFilter) return false;
    if (q.isEmpty) return true;
    return _searchHits.any((hit) => hit.convoId == c.id);
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
    final settings = ref.watch(settingsControllerProvider).value;
    final selectedTab = ref.watch(shellTabProvider);
    final workspaceTabs = ShellTab.visible(
      researchModeEnabled: settings?.researchModeEnabled ?? false,
      studyModeEnabled: settings?.studyModeEnabled ?? true,
      creationModeEnabled: settings?.creationModeEnabled ?? true,
    ).where((tab) => tab != ShellTab.settings).toList();
    final showWorkspaceLinks = MediaQuery.sizeOf(context).height >= 600;
    final showSettingsFooter = MediaQuery.sizeOf(context).height >= 480;
    final all = state?.conversations ?? const <Conversation>[];
    final visible = [
      for (final c in all)
        if (_matches(c, _query)) c,
    ];

    void openWorkspace(ShellTab tab) {
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
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 19,
                    color: scheme.onPrimary,
                  ),
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
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('sidebar-new-chat'),
                    onPressed: newConversation,
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text('新对话'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: '更多新建方式',
                  icon: const Icon(Icons.expand_more_rounded),
                  onSelected: (value) {
                    if (value == 'story') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DirectorStorySetupPage(),
                        ),
                      );
                    } else if (value == 'ensemble') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const EnsembleSetupPage(),
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'story',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.auto_stories_outlined),
                        title: Text('导演故事'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'ensemble',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.groups_outlined),
                        title: Text('角色大乱斗'),
                      ),
                    ),
                  ],
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
              onChanged: _scheduleSearch,
            ),
          ),
          if (showWorkspaceLinks) ...[
            const _SidebarSectionLabel('工作区'),
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
            child: _ModeFilterBar(
              selected: _modeFilter,
              onSelected: (mode) => setState(() => _modeFilter = mode),
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
                        final hit = _query.isEmpty
                            ? const SearchHit(
                                convoId: '',
                                messageId: '',
                                snippet: '',
                              )
                            : _searchHits.firstWhere(
                                (h) => h.convoId == c.id,
                                orElse: () => const SearchHit(
                                  convoId: '',
                                  messageId: '',
                                  snippet: '',
                                ),
                              );
                        final preview = hit.snippet.isNotEmpty
                            ? hit.snippet
                            : _conversationPreview(c);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Material(
                            color: selected
                                ? scheme.primaryContainer.withValues(
                                    alpha: 0.52,
                                  )
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(11),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(11),
                              onTap: () {
                                controller.selectConversation(c.id);
                                openShellTab(ref, ShellTab.chat);
                                if (hit.messageId.isNotEmpty) {
                                  ref
                                      .read(
                                        pendingJumpMessageIdProvider.notifier,
                                      )
                                      .set(hit.messageId);
                                }
                                _closeDrawerIfAny();
                              },
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(10, 7, 2, 7),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 30,
                                      height: 30,
                                      decoration: BoxDecoration(
                                        color: modeColor.withValues(
                                          alpha: 0.10,
                                        ),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Icon(
                                        ModeStyle.icon(c.mode),
                                        size: 16,
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
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: selected
                                                      ? FontWeight.w700
                                                      : FontWeight.w600,
                                                ),
                                          ),
                                          if (preview.isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              hit.snippet.isNotEmpty
                                                  ? '匹配：$preview'
                                                  : preview,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        hit.snippet.isNotEmpty
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
                                        ],
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: '会话操作',
                                      icon: const Icon(
                                        Icons.more_horiz,
                                        size: 19,
                                      ),
                                      padding: EdgeInsets.zero,
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
                                            style: TextStyle(
                                              color: scheme.error,
                                            ),
                                          ),
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
            if (showSettingsFooter) ...[
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.72),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: _WorkspaceDestination(
                  tab: ShellTab.settings,
                  selected: selectedTab == ShellTab.settings,
                  onTap: () => openWorkspace(ShellTab.settings),
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
          (
            id: ConversationMode.chat.name,
            label: ModeStyle.label(ConversationMode.chat),
            icon: ModeStyle.icon(ConversationMode.chat),
            mode: ConversationMode.chat,
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
