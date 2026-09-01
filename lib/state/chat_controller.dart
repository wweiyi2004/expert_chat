import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/chat_skill.dart';
import '../data/composer_modes.dart';
import '../data/library_models.dart';
import '../data/models.dart';
import '../data/story_models.dart';
import '../data/study_models.dart';
import '../domain/chat/chat_skill_router.dart';
import '../domain/chat/conversation_persistence.dart';
import '../domain/chat/conversation_tree.dart';
import '../domain/chat/error_describe.dart';
import '../domain/chat/long_task_runner.dart';
import '../domain/chat/tool_loop_policy.dart';
import '../domain/chat/stream_ui_coalescer.dart';
import '../domain/mcp/mcp_host_tools.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/media/image_codec_util.dart';
import '../domain/media/image_edit_reference.dart';
import '../domain/media/image_prompt_safety.dart';
import '../domain/notify/generation_notify.dart';
import '../domain/story/story_constraint_compiler.dart';
import '../domain/story/story_generation_intent.dart';
import '../domain/story/story_prompt_assembler.dart';
import '../domain/study/study_prompt_assembler.dart';
import '../domain/study/tutor_style.dart';
import '../domain/document/document_convert.dart';
import '../domain/document/document_edit_tools.dart';
import '../domain/document/document_patch.dart';
import '../domain/document/document_service_client.dart';
import '../domain/tools/search_orchestrator.dart';
import '../domain/tools/search_provider.dart';
import '../domain/tools/search_query.dart';
import '../domain/tools/tool_engine.dart';
import '../domain/tools/vision_tools.dart';
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

/// Which client tool to force this turn, or [kToolChoiceRequired] when more
/// than one "强制" chip is on. Document-edit force always wins.
String? forcedClientToolName({
  required bool forceDocument,
  required bool forceImage,
  required bool forceClientSearch,
}) {
  if (forceDocument) return DocumentEditTools.editDocumentToolName;
  if (forceImage && forceClientSearch) return kToolChoiceRequired;
  if (forceImage) return ToolEngine.generateImageTool.name;
  if (forceClientSearch) return ToolEngine.webSearchTool.name;
  return null;
}

/// Exact operation represented by an error banner's retry action.
///
/// A transcript alone is not enough to infer this safely: pure image turns,
/// ensemble turns and plot rewrites all need different replay semantics.
enum ChatRetryKind { regenerate, image, ensemble }

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

/// A completed turn is always persisted, but Android can reclaim a background
/// process before a long stream finishes. A low-frequency checkpoint protects
/// the in-progress user turn without turning every token into a DB write.
const _checkpointInterval = Duration(seconds: 3);
const _checkpointChars = 8192;

/// Shared notifier kernel: Riverpod lifecycle, live chat state, persistence
/// and long-task runners. Feature methods live in the mixins below so this
/// library stays one class with a stable public API.
abstract class _ChatControllerBase extends AsyncNotifier<ChatState> {
  StreamSubscription<dynamic>? _sub;
  Completer<void>? _streamCompleter;

  /// Set synchronously the instant a generation entry point is accepted, and
  /// cleared when it finishes. Guards the async window between the `isStreaming`
  /// check and [_generate] setting `streamingConvoId`: without it, two rapid
  /// sends (or send + regenerate) both pass the check while the first is still
  /// awaiting [_readySettings], starting two overlapping streams and leaking the
  /// first subscription.
  bool _starting = false;

  /// Set by [stop] so a generation that is still in the [_starting] window
  /// (awaiting settings / building the turn) aborts before [_generate] runs.
  /// Cleared when a new generation entry point is accepted.
  bool _cancelStart = false;

  /// Shared by callers that must wait until an accepted generation has fully
  /// unwound before starting a replacement turn.
  Completer<void>? _idleCompleter;

  /// Cancels the active LLM HTTP request (set per generation, fired by [stop]).
  CancelToken? _cancelToken;

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

  /// Conversations deleted while a generation was still in the [_starting]
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
      _sub?.cancel();
      _cancelToken?.cancel();
      // Stops local upload/polling only. Once a Gateway task id exists, the
      // durable server job intentionally keeps running.
      _longTaskRunner?.cancelAll('app disposed');
      final idle = _idleCompleter;
      _idleCompleter = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    });
    final repo = ref.read(conversationRepositoryProvider);
    final summaries = await repo.loadSummaries();
    SettingsState? settings;
    try {
      settings = await ref.read(settingsControllerProvider.future);
    } catch (_) {
      // Chat must still open if settings storage is corrupt.
    }
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
    try {
      loadedById[currentId] = await repo.loadConversation(currentId);
    } catch (_) {
      loadedById[currentId] = summaries.first.toPlaceholder().copyWith(
        messagesLoaded: true,
      );
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
    );
    // Let Riverpod publish [initial] before task runners begin mutating state.
    unawaited(Future<void>.delayed(Duration.zero, _resumeLongTasks));
    return initial;
  }

  ChatState get _s => state.value ?? const ChatState();

  void _finishStarting() {
    _starting = false;
    _signalIdleIfReady();
  }

  void _signalIdleIfReady() {
    if (_starting || _s.isStreaming) return;
    final idle = _idleCompleter;
    _idleCompleter = null;
    if (idle != null && !idle.isCompleted) idle.complete();
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
  LlmConfig _configFor(SettingsState settings) {
    if (!_s.deepThink) return settings.config;
    if (settings.config.capabilities.sendThinkingField) {
      return settings.config;
    }
    return settings.config.copyWith(model: settings.reasonerModel);
  }

  /// Image turns stay on a vision-capable chat model when deep-think's
  /// reasoner cannot accept pixels and no separate vision API is configured.
  LlmConfig _configForTurn(SettingsState settings, {required bool hasImages}) {
    final config = _configFor(settings);
    if (!hasImages ||
        config.capabilities.supportsVision ||
        settings.visionConfigured) {
      return config;
    }
    if (settings.config.capabilities.supportsVision) return settings.config;
    return config;
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
      final loaded = await ref
          .read(conversationRepositoryProvider)
          .loadConversation(id);
      if (!ref.mounted) return;
      final current = _s.conversations.indexWhere((c) => c.id == id);
      if (current < 0) return;
      if (_s.conversations[current].messagesLoaded) return;
      _set(_s.copyWith(conversations: _replace(loaded)));
    } catch (error) {
      if (!ref.mounted) return;
      _setScopedError('无法加载会话：$error', convoId: id);
    }
  }

  Future<void> selectConversation(String id) async {
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx >= 0 && !_s.conversations[idx].messagesLoaded) {
      await _ensureConversationLoaded(id);
      if (!ref.mounted) return;
    }
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

  Future<String> _studySystemPrompt(Conversation convo) async {
    final library = await ref.read(studyRepositoryProvider).load();
    StudySessionMeta? session;
    for (final candidate in library.sessions) {
      if (candidate.conversationId != convo.id) continue;
      session = candidate;
      break;
    }
    // Compatibility fallback for a study conversation imported after the v10
    // migration marker was written. New sessions never use authorNote.
    if (session == null) {
      final legacy = StudyPromptAssembler.decodeSessionNote(convo.authorNote);
      if (legacy != null) {
        session = StudySessionMeta.fromJson({
          ...legacy,
          'conversationId': convo.id,
          'createdAt': convo.updatedAt.toIso8601String(),
        });
      }
    }
    final topic = session?.topic.trim().isNotEmpty == true
        ? session!.topic.trim()
        : convo.title.replaceFirst(RegExp(r'^学习[：:]'), '').trim();
    final style = session?.tutorStyle ?? TutorStyle.mixed;
    final courseId = session?.courseId;
    final nodeId = session?.nodeId;
    String? courseTitle;
    String? nodeTitle;
    var notes = '';
    if ((courseId ?? '').isNotEmpty || (nodeId ?? '').isNotEmpty) {
      if ((courseId ?? '').isNotEmpty) {
        for (final course in library.courses) {
          if (course.id != courseId) continue;
          courseTitle = course.title;
          notes = course.sourceSummary.trim();
          break;
        }
      }
      if ((nodeId ?? '').isNotEmpty) {
        for (final node in library.nodes) {
          if (node.id != nodeId) continue;
          nodeTitle = node.title;
          break;
        }
      }
    }
    if (notes.characters.length > 4000) {
      notes = '${notes.characters.take(4000)}…';
    }
    return const StudyPromptAssembler().tutorSystem(
      style: style,
      topic: topic.isEmpty ? '通用学习' : topic,
      courseTitle: courseTitle,
      nodeTitle: nodeTitle,
      notes: notes,
    );
  }
}

class ChatController extends _ChatControllerBase
    with
        ChatMutations,
        ChatTools,
        ChatStreaming,
        ChatGeneration,
        ChatMedia,
        ChatTurns,
        ChatSessions {}

final chatControllerProvider = AsyncNotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

extension _ChatIterableFirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
