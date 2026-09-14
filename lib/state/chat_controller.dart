import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/chat_skill.dart';
import '../data/composer_modes.dart';
import '../data/db/app_database.dart' show GenerationRecord;
import '../data/generation_repository.dart';
import '../data/models.dart';
import '../data/story_models.dart';
import '../data/study_models.dart';
import '../domain/chat/chat_skill_router.dart';
import '../domain/chat/request_context_builder.dart';
import '../domain/chat/client_tool_prompt.dart';
import '../domain/chat/study_request_context.dart';
import '../domain/chat/conversation_persistence.dart';
import '../domain/chat/conversation_tree.dart';
import '../domain/chat/error_describe.dart';
import '../domain/chat/long_task_runner.dart';
import '../domain/chat/tool_loop_policy.dart';
import '../domain/chat/generation_execution.dart';
import '../domain/chat/tool_call_runner.dart';
import '../domain/chat/stream_ui_coalescer.dart';
import '../domain/chat/stream_answer_buffer.dart';
import '../domain/chat/stream_answer_presenter.dart';
import '../domain/mcp/mcp_host_tools.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/llm/llm_request_policy.dart';
import '../domain/media/image_reference_preparer.dart';
import '../domain/media/image_generation_service.dart';
import '../domain/media/image_prompt_optimizer.dart';
import '../domain/media/image_edit_reference.dart';
import '../domain/media/image_prompt_safety.dart';
import '../domain/notify/generation_notify.dart';
import '../domain/story/story_constraint_compiler.dart';
import '../domain/story/story_generation_intent.dart';
import '../domain/story/story_prompt_assembler.dart';
import '../domain/study/tutor_style.dart';
import '../domain/document/document_edit_tools.dart';
import '../domain/tools/search_orchestrator.dart';
import '../domain/tools/search_provider.dart';
import '../domain/tools/search_query.dart';
import '../domain/tools/tool_engine.dart';
import '../domain/tools/search_tool_executor.dart';
import '../domain/tools/vision_tools.dart';
import '../domain/tools/vision_tool_executor.dart';
import '../domain/tools/dialogue_image_executor.dart';
import '../domain/tools/document_tool_executor.dart';
import '../domain/tools/url_extract.dart';
import 'settings_controller.dart';
import 'study_controller.dart';

export '../data/composer_modes.dart';

part 'chat/sessions.dart';
part 'chat/turns.dart';
part 'chat/media.dart';
part 'chat/generation.dart';
part 'chat/streaming.dart';
part 'chat/tools.dart';
part 'chat/mutations.dart';
part 'chat/task_recovery.dart';

/// Which client tool to force this turn, or [kToolChoiceRequired] when more
/// than one "强制" chip is on. Document-edit force always wins.
String? forcedClientToolName({
  required bool forceDocument,
  required bool forceImage,
  required bool forceClientSearch,
}) {
  return LlmRequestPolicy.forcedToolChoice(
    documentTool: forceDocument ? DocumentEditTools.editDocumentToolName : null,
    imageTool: forceImage ? ToolEngine.generateImageTool.name : null,
    searchTool: forceClientSearch ? ToolEngine.webSearchTool.name : null,
  );
}

/// Exact operation represented by an error banner's retry action.
///
/// A transcript alone is not enough to infer this safely: pure image turns,
/// ensemble turns and plot rewrites all need different replay semantics.
enum ChatRetryKind { regenerate, image, ensemble, loadConversation }

class ChatRetryOperation {
  const ChatRetryOperation({
    required this.kind,
    required this.conversationId,
    required this.assistantMessageId,
    this.promptPlotCursor,
    this.commitPlotAdvance = false,
    this.storyIntent,
    this.ensembleSpeakerId,
  });

  const ChatRetryOperation.loadConversation(this.conversationId)
    : kind = ChatRetryKind.loadConversation,
      assistantMessageId = '',
      promptPlotCursor = null,
      commitPlotAdvance = false,
      storyIntent = null,
      ensembleSpeakerId = null;

  final ChatRetryKind kind;
  final String conversationId;
  final String assistantMessageId;

  /// Story cursor used only while assembling the retry prompt.
  final int? promptPlotCursor;

  /// Whether a successful retry should commit one plot beat.
  final bool commitPlotAdvance;

  /// Director-story action used to rebuild the same scoped prompt on retry.
  final StoryGenerationIntent? storyIntent;

  /// Speaker to preserve when retrying an ensemble turn.
  final String? ensembleSpeakerId;
}

/// Per-user-turn budget: dialogue may produce at most one image.
class _TurnImageBudget {
  int used = 0;
  static const maxPerTurn = 1;
  bool get canGenerate => used < maxPerTurn;
  void markUsed() => used++;
}

class ChatState {
  const ChatState({
    this.conversations = const [],
    this.currentId,
    this.streamingConvoId,
    this.deepThink = false,
    this.reasoningEffort = ReasoningEffort.high,
    this.searchMode = SearchMode.auto,
    this.imageGenMode = ImageGenMode.auto,
    this.isSearching = false,
    this.isGeneratingImage = false,
    this.isProcessingDocument = false,
    this.contextReports = const {},
    this.error,
    this.errorConvoId,
    this.retryOperation,
  });

  final List<Conversation> conversations;
  final String? currentId;

  /// Id of the conversation a generation is currently streaming into, or null
  /// when idle. Kept as an id (not a bool) so switching conversations mid-
  /// stream can't mis-attribute the stream to the newly selected one.
  final String? streamingConvoId;

  bool get isStreaming => streamingConvoId != null;

  /// When true the next send enables thinking (the "深度思考" toggle).
  /// DeepSeek V4 stays on the selected model and only flips `thinking`;
  /// providers without that field still switch to [SettingsState.reasonerModel].
  final bool deepThink;

  /// DeepSeek/Grok thinking intensity while [deepThink] is on.
  final ReasoningEffort reasoningEffort;

  /// Current "联网" switch position (off / auto / always).
  final SearchMode searchMode;

  /// Dialogue illustration mode (off / auto / always). Independent of the
  /// composer's pure "图片生成" mode, which bypasses chat entirely.
  final ImageGenMode imageGenMode;

  /// True while a web-search / fetch-url tool call is running (composer hint).
  final bool isSearching;

  /// True while an image generation request is in flight (composer hint).
  /// Kept separate from [isSearching] so 配图 / 生图 never show "正在联网搜索".
  final bool isGeneratingImage;

  /// True while inspect/edit/convert document tools are running.
  final bool isProcessingDocument;
  final Map<String, ContextWindowReport> contextReports;
  final String? error;

  /// Conversation the [error] belongs to. Banner must not show on other
  /// threads (e.g. A fails while the user is viewing B). Null = global /
  /// settings-style errors that apply regardless of selection.
  final String? errorConvoId;

  /// Exact failed operation, if the current error can be safely retried.
  final ChatRetryOperation? retryOperation;

  /// Whether [error] should be shown for the currently selected conversation.
  bool errorVisibleFor(String? convoId) {
    if (error == null) return false;
    if (errorConvoId == null) return true;
    return errorConvoId == convoId;
  }

  Conversation? get current {
    if (conversations.isEmpty) return null;
    return conversations.firstWhere(
      (c) => c.id == currentId,
      orElse: () => conversations.first,
    );
  }

  ChatState copyWith({
    List<Conversation>? conversations,
    String? currentId,
    Object? streamingConvoId = _sentinel,
    bool? deepThink,
    ReasoningEffort? reasoningEffort,
    SearchMode? searchMode,
    ImageGenMode? imageGenMode,
    bool? isSearching,
    bool? isGeneratingImage,
    bool? isProcessingDocument,
    Map<String, ContextWindowReport>? contextReports,
    Object? error = _sentinel,
    Object? errorConvoId = _sentinel,
    Object? retryOperation = _sentinel,
  }) {
    final nextError = identical(error, _sentinel)
        ? this.error
        : error as String?;
    final String? nextErrorConvoId;
    final ChatRetryOperation? nextRetryOperation;
    if (identical(error, _sentinel)) {
      nextErrorConvoId = identical(errorConvoId, _sentinel)
          ? this.errorConvoId
          : errorConvoId as String?;
      nextRetryOperation = identical(retryOperation, _sentinel)
          ? this.retryOperation
          : retryOperation as ChatRetryOperation?;
    } else if (nextError == null) {
      // Clearing the message always clears the scope.
      nextErrorConvoId = null;
      nextRetryOperation = null;
    } else if (identical(errorConvoId, _sentinel)) {
      // New error without an explicit scope → global (settings / setup).
      // Generation failures must pass [errorConvoId] via [_setScopedError].
      nextErrorConvoId = null;
      nextRetryOperation = identical(retryOperation, _sentinel)
          ? null
          : retryOperation as ChatRetryOperation?;
    } else {
      nextErrorConvoId = errorConvoId as String?;
      nextRetryOperation = identical(retryOperation, _sentinel)
          ? null
          : retryOperation as ChatRetryOperation?;
    }
    return ChatState(
      conversations: conversations ?? this.conversations,
      currentId: currentId ?? this.currentId,
      streamingConvoId: identical(streamingConvoId, _sentinel)
          ? this.streamingConvoId
          : streamingConvoId as String?,
      deepThink: deepThink ?? this.deepThink,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      searchMode: searchMode ?? this.searchMode,
      imageGenMode: imageGenMode ?? this.imageGenMode,
      isSearching: isSearching ?? this.isSearching,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      isProcessingDocument: isProcessingDocument ?? this.isProcessingDocument,
      contextReports: contextReports ?? this.contextReports,
      error: nextError,
      errorConvoId: nextErrorConvoId,
      retryOperation: nextRetryOperation,
    );
  }

  static const _sentinel = Object();
}

/// Shown when the final (tool-withheld) model round still answers with tool
/// calls instead of text, so the turn is never left blank.
const _emptyReplyFallback = '模型未能输出有效回复，请重试。';

/// A reasoning model can consume its entire output allowance before it
/// reaches the public answer channel. In that case the reasoning is not a
/// safe substitute for a final answer because it may be incomplete.
const _reasoningLimitFallback =
    '模型的思考过程占满了输出额度，未能生成最终正文。'
    '请重试；若已开启深度思考，可关闭后再试。';

const _maxToolCallsPerRound = ToolLoopPolicy.chatCallsPerRound;

/// Shared notifier kernel: Riverpod lifecycle, live chat state, persistence
/// and long-task runners. Feature methods live in the mixins below so this
/// library stays one class with a stable public API.
abstract class _ChatControllerBase extends AsyncNotifier<ChatState> {
  int _conversationSelectionRevision = 0;
  final _execution = GenerationExecution();

  void _beginTaskBudget(SettingsState settings) {
    _execution.beginBudget(
      settings.taskBudget,
      beforeCancel: () {
        if (ref.mounted) _flushActiveStream?.call();
      },
    );
  }

  /// Invoked by [stop] before it snapshots the conversation, so a scheduled UI
  /// flush cannot leave the last received tokens out of the saved transcript.
  void Function()? _flushActiveStream;

  /// Stick-to-bottom: the user is following the live tail.
  bool _streamFollowingTail = true;

  /// Thinking panel expanded on the in-flight assistant bubble.
  bool _streamThinkingExpanded = true;

  /// True once the current stream has emitted visible answer tokens.
  bool _streamHasLiveContent = false;

  StreamUiFocus get _streamUiFocus => streamUiFocusFor(
    followingTail: _streamFollowingTail,
    hasContent: _streamHasLiveContent,
    thinkingExpanded: _streamThinkingExpanded,
  );

  /// Live catch-up when the user looks back at a streaming pane.
  void Function()? _nudgeStreamUi;

  /// Chat page reports scroll/thinking-panel attention during a live stream.
  void reportStreamView({
    required bool followingTail,
    required bool thinkingExpanded,
  }) {
    if (_streamFollowingTail == followingTail &&
        _streamThinkingExpanded == thinkingExpanded) {
      return;
    }
    final before = _streamUiFocus;
    _streamFollowingTail = followingTail;
    _streamThinkingExpanded = thinkingExpanded;
    if (_streamUiFocus != before && _streamUiFocus != StreamUiFocus.away) {
      _nudgeStreamUi?.call();
    }
  }

  /// Conversations deleted while a generation was still in the [_execution.isActive]
  /// preflight window. [_generate] consults this tombstone to abandon (not
  /// resurrect) a turn whose target was deleted before streaming began.
  final Set<String> _deletedWhileStartingIds = {};

  /// Background document jobs are independent from the one ordinary chat SSE
  /// stream. Several conversations may have one running at the same time.
  /// Lazily created because [ref] is not readable during field
  /// initialization; the injected closures defer every [ref] access.
  LongTaskRunner? _longTaskRunner;
  LongTaskRunner get _longTasks => _longTaskRunner ??= LongTaskRunner(
    client: () => ref.read(longTaskGatewayClientProvider),
    readSettings: () => ref.read(settingsControllerProvider.future),
    conversations: () => _s.conversations,
    findTask: _findLongTask,
    writeTask: _writeLongTask,
    reportError: (error, {convoId}) => _setScopedError(error, convoId: convoId),
  );

  /// Serialized conversation persistence (write queue + stream checkpoints).
  /// Lazily created because [ref] is not readable during field
  /// initialization; the injected closures defer every [ref] access.
  ConversationPersistence? _conversationPersistence;
  ConversationPersistence get _persistence =>
      _conversationPersistence ??= ConversationPersistence(
        repository: () => ref.read(conversationRepositoryProvider),
        currentConversation: () => _s.current,
        conversations: () => _s.conversations,
        mounted: () => ref.mounted,
        reportFailure: (message, {convoId}) =>
            _setScopedError(message, convoId: convoId),
      );

  @override
  Future<ChatState> build() async {
    // Reading conversation history must not wait for secure-storage/settings
    // I/O. Restore composer defaults once both independent loads are ready.
    final startupSettings = ref.read(settingsControllerProvider.future);
    unawaited(
      startupSettings
          .then((settings) async {
            await future;
            if (!ref.mounted) return;
            final effort = _editedComposerPrefs.contains('effort')
                ? _s.reasoningEffort
                : settings.reasoningEffort;
            final search = _editedComposerPrefs.contains('search')
                ? _s.searchMode
                : settings.searchMode;
            final image = _editedComposerPrefs.contains('image')
                ? _s.imageGenMode
                : settings.imageGenMode;
            if (_s.reasoningEffort != effort ||
                _s.searchMode != search ||
                _s.imageGenMode != image) {
              _set(
                _s.copyWith(
                  reasoningEffort: effort,
                  searchMode: search,
                  imageGenMode: image,
                ),
              );
            }
          })
          .catchError((Object _) {}),
    );
    ref.onDispose(() {
      // Riverpod 3 rejects state writes once the element is disposed, so the
      // flush can throw (UnmountedRefException / lifecycle assert). It must not
      // abort the teardown below; any checkpoint it would have scheduled is
      // already best-effort and the repository write queue survives dispose.
      try {
        _flushActiveStream?.call();
      } catch (_) {
        // Dispose-time state write is not allowed; keep tearing down.
      }
      _execution.dispose();
      // Durable Gateway jobs keep running remotely after local teardown.
      _longTaskRunner?.cancelAll('app disposed');
    });
    final repo = ref.read(conversationRepositoryProvider);
    final summaries = await repo.loadSummaries();
    final settings = ref.read(settingsControllerProvider).value;
    final effort = settings?.reasoningEffort ?? ReasoningEffort.high;
    final searchMode = settings?.searchMode ?? SearchMode.auto;
    final imageGenMode = settings?.imageGenMode ?? ImageGenMode.auto;
    if (summaries.isEmpty) {
      final fresh = Conversation();
      return ChatState(
        conversations: [fresh],
        currentId: fresh.id,
        reasoningEffort: effort,
        searchMode: searchMode,
        imageGenMode: imageGenMode,
      );
    }
    final currentId = summaries.first.id;
    final loadedById = <String, Conversation>{};
    String? loadError;
    try {
      loadedById[currentId] = await repo.loadConversation(currentId);
    } catch (error) {
      // An empty placeholder is not an empty archive. Keeping it unloaded
      // makes metadata-only saves preserve every existing message row.
      loadedById[currentId] = summaries.first.toPlaceholder();
      loadError = '无法加载会话：$error';
    }
    for (final summary in summaries) {
      if (!summary.hasActiveLongTask || loadedById.containsKey(summary.id)) {
        continue;
      }
      try {
        loadedById[summary.id] = await repo.loadConversation(summary.id);
      } catch (_) {
        // Resume is best-effort; the placeholder stays unloaded.
      }
    }
    final conversations = [
      for (final summary in summaries)
        loadedById[summary.id] ?? summary.toPlaceholder(),
    ];
    final initial = ChatState(
      conversations: conversations,
      currentId: currentId,
      reasoningEffort: effort,
      searchMode: searchMode,
      imageGenMode: imageGenMode,
      error: loadError,
      errorConvoId: loadError == null ? null : currentId,
      retryOperation: loadError == null
          ? null
          : ChatRetryOperation.loadConversation(currentId),
    );
    // Let Riverpod publish [initial] before task runners begin mutating state.
    unawaited(Future<void>.delayed(Duration.zero, _resumeLongTasks));
    return initial;
  }

  ChatState get _s => state.value ?? const ChatState();
  final Set<String> _editedComposerPrefs = {};

  void _finishStarting() {
    if (!ref.mounted) {
      _execution.finish();
      return;
    }
    final timedOutId = _s.streamingConvoId;
    if ((_execution.budget?.finishing ?? false) &&
        timedOutId != null &&
        !_execution.isCancelled) {
      _set(
        _s.copyWith(
          streamingConvoId: null,
          isSearching: false,
          isGeneratingImage: false,
          isProcessingDocument: false,
          error: '${_execution.budget!.reason}；已停止本地等待，远端状态未确认。',
          errorConvoId: timedOutId,
        ),
      );
      _persistence.persistSoon(_persistence.persistById(timedOutId));
    }
    _execution.finish();
  }

  void _set(ChatState next) => state = AsyncData(next);

  /// Error banner scoped to a conversation (in-flight stream or current).
  void _setScopedError(
    String message, {
    String? convoId,
    ChatRetryOperation? retryOperation,
  }) {
    _set(
      _s.copyWith(
        error: message,
        errorConvoId: convoId ?? _s.streamingConvoId ?? _s.currentId,
        retryOperation: retryOperation,
      ),
    );
  }

  /// Replace the current conversation in the list with [updated].
  List<Conversation> _replace(Conversation updated) => [
    for (final c in _s.conversations) c.id == updated.id ? updated : c,
  ];

  /// Validate settings; returns null (and sets an error) when not ready.
  Future<SettingsState?> _readySettings() async {
    final settings = await ref.read(settingsControllerProvider.future);
    if (!settings.config.isReady) {
      _set(_s.copyWith(error: '请先在设置中填写 API Key。'));
      return null;
    }
    return settings;
  }

  Future<SettingsState?> _readySettingsForTurn({
    bool requireVision = false,
  }) async {
    final settings = await ref.read(settingsControllerProvider.future);
    if (requireVision) {
      final config = _configForTurn(settings, hasImages: true);
      if (!settings.visionConfigured && !config.capabilities.supportsVision) {
        _set(
          _s.copyWith(
            error:
                '当前模型不支持看图。请选用视觉模型（如 ${KnownModels.vision}），'
                '或在设置中配置独立视觉 API。',
          ),
        );
        return null;
      }
    }
    if (!settings.config.isReady) {
      _set(_s.copyWith(error: '请先在设置中填写 API Key。'));
      return null;
    }
    return settings;
  }

  /// Deep-think config for this turn.
  ///
  /// Models that accept DeepSeek's `thinking` field (V4 flash/pro/vision)
  /// stay on the selected model and only enable thinking. Providers without
  /// that field still switch to the profile's dedicated reasoner model.
  LlmConfig _configFor(SettingsState settings) =>
      _configForTurn(settings, hasImages: false);

  /// Image turns stay on a vision-capable chat model when deep-think's
  /// reasoner cannot accept pixels and no separate vision API is configured.
  LlmConfig _configForTurn(SettingsState settings, {required bool hasImages}) {
    return LlmRequestPolicy.selectModel(
      selected: settings.config,
      reasonerModel: settings.reasonerModel,
      thinking: _s.deepThink,
      hasImages: hasImages,
      hasVisionFallback: settings.visionConfigured,
    );
  }

  LongTaskState? _findLongTask(String convoId, String assistantId);
  Future<void> _writeLongTask(
    String convoId,
    String assistantId,
    LongTaskState task, {
    String? content,
  });
  Future<void> _resumeLongTasks();

  Future<void> _ensureConversationLoaded(String id) async {
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    if (_s.conversations[idx].messagesLoaded) return;
    try {
      late Conversation loaded;
      // A queued rename or other metadata save must finish before reading.
      await _persistence.enqueueWrite(() async {
        loaded = await ref
            .read(conversationRepositoryProvider)
            .loadConversation(id);
      });
      if (!ref.mounted) return;
      final current = _s.conversations.indexWhere((c) => c.id == id);
      if (current < 0) return;
      if (_s.conversations[current].messagesLoaded) return;
      // Metadata can also change while the read itself is in flight. The live
      // header owns those edits; only install the previously unloaded body.
      final restored = _s.conversations[current].copyWith(
        messages: loaded.messages,
        messagesLoaded: true,
      );
      final clearsLoadError =
          _s.retryOperation?.kind == ChatRetryKind.loadConversation &&
          _s.retryOperation?.conversationId == id;
      _set(
        _s.copyWith(
          conversations: _replace(restored),
          error: clearsLoadError ? null : _s.error,
        ),
      );
    } catch (error) {
      if (!ref.mounted) return;
      _setScopedError(
        '无法加载会话：$error',
        convoId: id,
        retryOperation: ChatRetryOperation.loadConversation(id),
      );
    }
  }

  bool _requireLoadedConversation(Conversation conversation) {
    if (conversation.messagesLoaded) return true;
    _setScopedError(
      '会话尚未加载，请先点击重试恢复历史记录。',
      convoId: conversation.id,
      retryOperation: ChatRetryOperation.loadConversation(conversation.id),
    );
    return false;
  }

  Future<void> selectConversation(String id) async {
    final revision = ++_conversationSelectionRevision;
    final previousCurrentId = _s.currentId;
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx >= 0 && !_s.conversations[idx].messagesLoaded) {
      await _ensureConversationLoaded(id);
      if (!ref.mounted) return;
      // Loading a large archive must not steal focus from a newer selection,
      // newly created conversation, or deletion fallback.
      if (revision != _conversationSelectionRevision ||
          _s.currentId != previousCurrentId) {
        return;
      }
    }
    if (!_s.conversations.any((c) => c.id == id)) return;
    // A failure that belongs to another conversation stays parked until the
    // user returns to it. Clearing it here made background failures impossible
    // to discover: hidden on B, then erased while selecting A.
    if (_s.error != null && _s.errorConvoId != null) {
      _set(_s.copyWith(currentId: id));
    } else {
      _set(_s.copyWith(currentId: id, error: null));
    }
  }

  String _titleFor(String? convoId) {
    if (convoId == null) return _s.current?.title ?? '对话';
    for (final c in _s.conversations) {
      if (c.id == convoId) return c.title;
    }
    return _s.current?.title ?? '对话';
  }

  String _previewFor(String convoId, String assistantId) {
    for (final c in _s.conversations) {
      if (c.id != convoId) continue;
      for (final m in c.messages) {
        if (m.id == assistantId) {
          final t = m.content.trim();
          return t.isEmpty ? m.reasoning.trim() : t;
        }
      }
    }
    return '';
  }

  Future<String> _studySystemPrompt(Conversation convo) async =>
      StudyRequestContext.build(
        convo,
        await ref.read(studyRepositoryProvider).load(),
      );
}

class ChatController extends _ChatControllerBase
    with
        ChatMutations,
        ChatTools,
        ChatStreaming,
        ChatGeneration,
        ChatMedia,
        ChatTurns,
        ChatSessions,
        ChatTaskRecovery {}

final chatControllerProvider = AsyncNotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

extension _ChatIterableFirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
