import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/models.dart';
import '../data/story_models.dart';
import '../domain/context/context_window_manager.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/media/image_codec_util.dart';
import '../domain/media/image_prompt_safety.dart';
import '../domain/notify/generation_notify.dart';
import '../domain/story/story_length_budget.dart';
import '../domain/story/story_prompt_assembler.dart';
import '../domain/tools/search_orchestrator.dart';
import '../domain/tools/search_provider.dart';
import '../domain/tools/search_query.dart';
import '../domain/tools/tool_engine.dart';
import '../domain/tools/url_extract.dart';
import 'settings_controller.dart';

/// Composer "联网" switch. [off] never searches; [auto] lets the model (or the
/// planner, for tool-less models) decide per question; [always] guarantees at
/// least one search before answering.
enum SearchMode { off, auto, always }

extension SearchModeInfo on SearchMode {
  SearchMode get next => switch (this) {
    SearchMode.off => SearchMode.auto,
    SearchMode.auto => SearchMode.always,
    SearchMode.always => SearchMode.off,
  };

  String get composerLabel => switch (this) {
    SearchMode.off => '联网',
    SearchMode.auto => '联网·自动',
    SearchMode.always => '联网·强制',
  };
}

/// Composer "配图" switch for **dialogue** image generation (not pure 生图 mode).
///
/// - [off]: model cannot generate images in chat
/// - [auto]: tool-capable models may call `generate_image` at most once / turn
/// - [always]: guarantee one SFW image before/with the answer (pre-gen)
enum ImageGenMode { off, auto, always }

extension ImageGenModeInfo on ImageGenMode {
  ImageGenMode get next => switch (this) {
    ImageGenMode.off => ImageGenMode.auto,
    ImageGenMode.auto => ImageGenMode.always,
    ImageGenMode.always => ImageGenMode.off,
  };

  String get composerLabel => switch (this) {
    ImageGenMode.off => '配图',
    ImageGenMode.auto => '配图·自动',
    ImageGenMode.always => '配图·强制',
  };
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
    this.ensembleSpeakerId,
  });

  final ChatRetryKind kind;
  final String conversationId;
  final String assistantMessageId;

  /// Story cursor used only while assembling the retry prompt.
  final int? promptPlotCursor;

  /// Whether a successful retry should commit one plot beat.
  final bool commitPlotAdvance;

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
    this.searchMode = SearchMode.off,
    this.imageGenMode = ImageGenMode.off,
    this.isSearching = false,
    this.isGeneratingImage = false,
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

  /// When true the next send is routed to the reasoner model regardless of the
  /// configured default model (the "深度思考" toggle in the composer).
  final bool deepThink;

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
    SearchMode? searchMode,
    ImageGenMode? imageGenMode,
    bool? isSearching,
    bool? isGeneratingImage,
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
      searchMode: searchMode ?? this.searchMode,
      imageGenMode: imageGenMode ?? this.imageGenMode,
      isSearching: isSearching ?? this.isSearching,
      isGeneratingImage: isGeneratingImage ?? this.isGeneratingImage,
      contextReports: contextReports ?? this.contextReports,
      error: nextError,
      errorConvoId: nextErrorConvoId,
      retryOperation: nextRetryOperation,
    );
  }

  static const _sentinel = Object();
}

class ChatController extends AsyncNotifier<ChatState> {
  static const int _maxToolCallsPerRound = 3;

  /// Streaming providers often emit many tiny SSE chunks per second. Coalescing
  /// them keeps the message list, markdown renderer and scroll controller from
  /// rebuilding for every token while still feeling live to the user.
  static const _streamUiFlushInterval = Duration(milliseconds: 50);

  /// A completed turn is always persisted, but Android can reclaim a background
  /// process before a long stream finishes. A low-frequency checkpoint protects
  /// the in-progress user turn without turning every token into a DB write.
  static const _checkpointInterval = Duration(seconds: 3);
  static const int _checkpointChars = 8192;

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

  /// Serializes repository writes. Several UI actions intentionally don't await
  /// persistence; without a queue an older snapshot can finish after a newer
  /// one and overwrite it (especially around stop / rename / branch switches).
  Future<void> _writeQueue = Future<void>.value();

  /// A slow disk must not let periodic stream checkpoints pile up behind one
  /// another. The final turn write is still awaited separately, so dropping an
  /// overlapping best-effort checkpoint cannot lose the completed answer.
  final Set<String> _checkpointWritesInFlight = {};

  @override
  Future<ChatState> build() async {
    ref.onDispose(() {
      _flushActiveStream?.call();
      _sub?.cancel();
      _cancelToken?.cancel();
      final idle = _idleCompleter;
      _idleCompleter = null;
      if (idle != null && !idle.isCompleted) idle.complete();
    });
    final repo = ref.read(conversationRepositoryProvider);
    final conversations = await repo.loadAll();
    if (conversations.isEmpty) {
      final fresh = Conversation();
      return ChatState(conversations: [fresh], currentId: fresh.id);
    }
    return ChatState(
      conversations: conversations,
      currentId: conversations.first.id,
    );
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

  /// Persist only the active conversation (cheap; avoids rewriting the whole DB
  /// on every turn).
  Future<void> _enqueueWrite(Future<void> Function() operation) {
    // Keep future writes alive even when one write fails. The caller still gets
    // the individual failure, while the queue remains usable for later turns.
    final queued = _writeQueue
        .catchError((Object _) {})
        .then((_) => operation());
    _writeQueue = queued;
    return queued;
  }

  Future<void> _persist() {
    final cur = _s.current;
    if (cur == null) return Future.value();
    return _enqueueWrite(
      () => ref.read(conversationRepositoryProvider).saveConversation(cur),
    );
  }

  /// Persist a specific conversation by id. Used by the generation pipeline so
  /// the streamed conversation is saved even if the user switched to another
  /// one mid-stream. No-op when the conversation was deleted meanwhile (so a
  /// late save can't resurrect it).
  Future<void> _persistById(String convoId) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return Future.value();
    final convo = _s.conversations[idx];
    return _enqueueWrite(
      () => ref.read(conversationRepositoryProvider).saveConversation(convo),
    );
  }

  Future<void> _deletePersistedConversation(String id) => _enqueueWrite(
    () => ref.read(conversationRepositoryProvider).deleteConversation(id),
  );

  /// UI callbacks should remain responsive, but persistence failures must never
  /// become unhandled async errors. Surface them in the existing error banner
  /// so the user knows a local archive operation needs attention.
  void _persistSoon(Future<void> write) {
    unawaited(_reportPersistFailure(write));
  }

  Future<void> _reportPersistFailure(Future<void> write) async {
    try {
      await write;
    } catch (e) {
      if (ref.mounted) _setScopedError('本地保存失败：$e');
    }
  }

  void _checkpointSoon(String conversationId) {
    if (!_checkpointWritesInFlight.add(conversationId)) return;
    unawaited(_runCheckpoint(conversationId));
  }

  Future<void> _runCheckpoint(String conversationId) async {
    try {
      await _reportPersistFailure(_persistById(conversationId));
    } finally {
      _checkpointWritesInFlight.remove(conversationId);
    }
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

  /// Root-to-node path across any branch, used to retry the exact failed turn
  /// even if the user briefly switched branches before pressing retry.
  List<ChatMessage> _pathToMessage(Conversation convo, String messageId) {
    final byId = {for (final m in convo.messages) m.id: m};
    final reversed = <ChatMessage>[];
    final seen = <String>{};
    ChatMessage? current = byId[messageId];
    while (current != null && seen.add(current.id)) {
      reversed.add(current);
      final parentId = current.parentId;
      current = parentId == null ? null : byId[parentId];
    }
    return reversed.reversed.toList();
  }

  Map<String, String> _activatePath(
    Map<String, String> current,
    List<ChatMessage> path,
  ) {
    final next = Map<String, String>.of(current);
    for (final message in path) {
      next[message.parentId ?? kRootKey] = message.id;
    }
    return next;
  }

  void newConversation() {
    final fresh = Conversation();
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
    _persistSoon(_persist());
  }

  Future<List<String>> _defaultWorldInfoIds() async {
    final entries = await ref.read(worldInfoRepositoryProvider).loadAll();
    return [
      for (final e in entries)
        if (e.enabled) e.id,
    ];
  }

  /// Start a story session bound to [card]. Defaults to all enabled world-info
  /// entries; optional [worldInfoIds] overrides the selection.
  Future<void> newStoryConversation(
    CharacterCard card, {
    List<String>? worldInfoIds,
  }) async {
    final ids = worldInfoIds ?? await _defaultWorldInfoIds();

    final messages = <ChatMessage>[];
    final activeChildren = <String, String>{};
    final firstMes = card.firstMes.trim();
    if (firstMes.isNotEmpty) {
      final opener = ChatMessage(
        role: MessageRole.assistant,
        content: firstMes,
        parentId: null,
        speakerId: card.id,
        speakerName: card.name,
      );
      messages.add(opener);
      activeChildren[kRootKey] = opener.id;
    }

    final fresh = Conversation(
      title: card.name,
      mode: ConversationMode.story,
      characterId: card.id,
      participantIds: [card.id],
      worldInfoIds: ids,
      messages: messages,
      activeChildren: activeChildren,
    );
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
    _persistSoon(_persist());
  }

  /// Create a story in which the model performs the narrator and every
  /// story-local character while the user acts only as the director.
  Future<void> newDirectorStoryConversation({
    required String title,
    required String premise,
    required List<CharacterCard> cast,
    required String outline,
    String authorNote = '',
    String requirements = '',
    List<String>? worldInfoIds,
    int targetTotalChars = 0,
  }) async {
    final usableCast = cast
        .where((card) => card.name.trim().isNotEmpty)
        .toList();
    if (usableCast.isEmpty) {
      _set(_s.copyWith(error: '导演故事至少需要一个 AI 角色。'));
      return;
    }
    if (outline.trim().isEmpty) {
      _set(_s.copyWith(error: '请先生成或填写故事大纲。'));
      return;
    }

    final ids = worldInfoIds ?? await _defaultWorldInfoIds();
    final premiseText = premise.trim();
    final noteText = authorNote.trim();
    final reqText = requirements.trim();
    // Constraints first so later clipping keeps the hard rules.
    final combinedNote = [
      if (reqText.isNotEmpty) '【硬性创作约束】（不可违背）\n$reqText',
      if (noteText.isNotEmpty) noteText,
      if (premiseText.isNotEmpty) '【故事原始情节】（核心基调与事件不可擅自改写）\n$premiseText',
    ].join('\n\n');
    final resolvedTitle = title.trim().isEmpty
        ? (premiseText.isEmpty ? '导演故事' : premiseText)
        : title.trim();

    final fresh = Conversation(
      title: resolvedTitle,
      mode: ConversationMode.story,
      participantIds: [for (final card in usableCast) card.id],
      localCast: List.unmodifiable(usableCast),
      worldInfoIds: ids,
      outline: outline.trim(),
      authorNote: combinedNote,
      plotCursor: 0,
      targetTotalChars: targetTotalChars < 0 ? 0 : targetTotalChars,
    );
    // The setup draft is cleared immediately after this method succeeds.
    // Persist first so a failed/unfinished disk write cannot lose both copies.
    await _enqueueWrite(
      () => ref.read(conversationRepositoryProvider).saveConversation(fresh),
    );
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
  }

  /// Multi-character ensemble: cast in one [venue], taking turns.
  Future<void> newEnsembleConversation({
    required List<CharacterCard> cast,
    required String venue,
    String authorNote = '',
    List<String>? worldInfoIds,
  }) async {
    if (cast.length < 2) {
      _set(_s.copyWith(error: '角色大乱斗至少需要 2 名角色。'));
      return;
    }
    final ids = worldInfoIds ?? await _defaultWorldInfoIds();
    final place = venue.trim().isEmpty ? '同一空间' : venue.trim();
    final title = cast.map((c) => c.name).take(3).join('·');
    final names = cast.map((c) => c.name).join('、');

    final systemIntro = ChatMessage(
      role: MessageRole.assistant,
      content:
          '【场景】$place\n'
          '【在场】$names\n'
          '你们已聚在一起。可由导演下达指令，或点「下一位发言 / 自动轮流」让角色对谈。',
      speakerName: '旁白',
    );

    final fresh = Conversation(
      title: cast.length <= 3 ? title : '$title…',
      mode: ConversationMode.ensemble,
      characterId: cast.first.id,
      participantIds: [for (final c in cast) c.id],
      worldInfoIds: ids,
      venue: place,
      authorNote: authorNote,
      nextSpeakerIndex: 0,
      messages: [systemIntro],
      activeChildren: {kRootKey: systemIntro.id},
    );
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
    _persistSoon(_persist());
  }

  /// Update story-session metadata on the current (or [conversationId]) chat.
  void updateStoryMeta({
    String? conversationId,
    String? outline,
    String? authorNote,
    List<String>? worldInfoIds,
    int? plotCursor,
    String? venue,
    List<String>? participantIds,
    int? nextSpeakerIndex,
    int? targetTotalChars,
  }) {
    final id = conversationId ?? _s.currentId;
    if (id == null) return;
    final idx = _s.conversations.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    final convo = _s.conversations[idx];
    if (!convo.isStoryLike) return;

    final beatsLen = parseOutlineBeats(outline ?? convo.outline).length;
    final nextCursor = plotCursor == null
        ? null
        : (beatsLen == 0
              ? plotCursor.clamp(0, 9999)
              : plotCursor.clamp(0, beatsLen));

    final cast = participantIds ?? convo.participantIds;
    final nextIdx = nextSpeakerIndex == null
        ? null
        : (cast.isEmpty ? 0 : nextSpeakerIndex.clamp(0, cast.length - 1));

    final nextTarget = targetTotalChars == null
        ? null
        : (targetTotalChars < 0 ? 0 : targetTotalChars);

    final updated = convo.copyWith(
      outline: outline,
      authorNote: authorNote,
      worldInfoIds: worldInfoIds,
      plotCursor: nextCursor,
      venue: venue,
      participantIds: participantIds,
      nextSpeakerIndex: nextIdx,
      targetTotalChars: nextTarget,
    );
    _set(_s.copyWith(conversations: _replace(updated)));
    _persistSoon(
      _enqueueWrite(
        () =>
            ref.read(conversationRepositoryProvider).saveConversation(updated),
      ),
    );
  }

  /// Nudge plot cursor by [delta] on the current story conversation.
  void adjustPlotCursor(int delta) {
    final convo = _s.current;
    if (convo == null || !convo.isStory) return;
    final beats = convo.outlineBeats;
    final max = beats.isEmpty
        ? convo.plotCursor + delta.abs() + 1
        : beats.length;
    final next = (convo.plotCursor + delta).clamp(0, max);
    updateStoryMeta(plotCursor: next);
  }

  /// Generate the next plot beat (visible user turn "（推进情节）").
  Future<void> advancePlot() async {
    if (_s.isStreaming || _starting) return;
    final convo = _s.current;
    if (convo == null || !convo.isStory) return;

    _starting = true;
    _cancelStart = false;
    try {
      final settings = await _readySettings();
      if (settings == null || _cancelStart) return;
      final config = _configFor(settings);

      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      final directorCue = convo.plotCursor == 0 && convo.activePath.isEmpty
          ? '（导演：开始第一节）'
          : '（导演：继续下一节）';
      final userMsg = ChatMessage(
        role: MessageRole.user,
        content: convo.localCast.isNotEmpty ? directorCue : '（推进情节）',
        parentId: parentId,
      );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: userMsg.id,
      );
      final working = convo.copyWith(
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: {
          ...convo.activeChildren,
          parentId ?? kRootKey: userMsg.id,
          userMsg.id: assistantMsg.id,
        },
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: '',
        thinking: _s.deepThink,
        advancePlot: true,
        commitPlotAdvance: true,
      );
    } finally {
      _finishStarting();
    }
  }

  /// User bubbles that mean "advance the outline", including director cues.
  static bool isPlotAdvanceUserContent(String content) {
    final c = content.trim();
    return c == '（推进情节）' || c == '（导演：继续下一节）' || c == '（导演：开始第一节）';
  }

  /// One AI line from the next cast member (round-robin).
  Future<void> ensembleNextTurn({String? forceCharacterId}) async {
    if (_s.isStreaming || _starting) return;
    final convo = _s.current;
    if (convo == null || !convo.isEnsemble) return;
    final castIds = convo.castIds;
    if (castIds.length < 2) {
      _set(_s.copyWith(error: '角色大乱斗需要至少 2 名角色。'));
      return;
    }

    var index = forceCharacterId != null
        ? castIds.indexOf(forceCharacterId)
        : convo.nextSpeakerIndex % castIds.length;
    if (index < 0) index = 0;
    final speakerId = castIds[index];
    final card = await ref.read(characterRepositoryProvider).getById(speakerId);
    if (card == null) {
      _set(_s.copyWith(error: '找不到角色卡，请检查参与名单。'));
      return;
    }

    _starting = true;
    _cancelStart = false;
    try {
      final settings = await _readySettings();
      if (settings == null || _cancelStart) return;
      final config = _configFor(settings);

      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: parentId,
        speakerId: card.id,
        speakerName: card.name,
      );
      final nextIndex = (index + 1) % castIds.length;
      final working = convo.copyWith(
        messages: [...convo.messages, assistantMsg],
        activeChildren: {
          ...convo.activeChildren,
          parentId ?? kRootKey: assistantMsg.id,
        },
        nextSpeakerIndex: nextIndex,
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: '',
        thinking: _s.deepThink,
        ensembleSpeaker: card,
      );
    } finally {
      _finishStarting();
    }
  }

  /// Auto-run [rounds] ensemble turns (or until stop).
  Future<void> ensembleAutoPlay({int rounds = 6}) async {
    final n = rounds.clamp(1, 20);
    for (var i = 0; i < n; i++) {
      final current = _s.current;
      if (current == null || !current.isEnsemble) return;
      if (_s.isStreaming || _starting) return;
      await ensembleNextTurn();
      // Allow UI to settle between turns.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final after = _s.current;
      if (_cancelStart || after == null || !after.isEnsemble) return;
      final err = _s.error;
      if (err != null && err.isNotEmpty) return;
    }
  }

  void selectConversation(String id) {
    // A failure that belongs to another conversation stays parked until the
    // user returns to it. Clearing it here made background failures impossible
    // to discover: hidden on B, then erased while selecting A.
    if (_s.error != null && _s.errorConvoId != null) {
      _set(_s.copyWith(currentId: id));
    } else {
      _set(_s.copyWith(currentId: id, error: null));
    }
  }

  /// Toggle the "深度思考" switch shown next to the composer.
  void toggleDeepThink() {
    _set(_s.copyWith(deepThink: !_s.deepThink));
  }

  /// Cycle the "联网" switch shown next to the composer: 关 → 自动 → 强制 → 关.
  void toggleSearch() {
    _set(_s.copyWith(searchMode: _s.searchMode.next));
  }

  /// Cycle dialogue "配图": 关 → 自动 → 强制 → 关.
  void toggleImageGenMode() {
    _set(_s.copyWith(imageGenMode: _s.imageGenMode.next));
  }

  void renameConversation(String id, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    Conversation? renamed;
    final updated = [
      for (final c in _s.conversations)
        if (c.id == id) (renamed = c.copyWith(title: trimmed)) else c,
    ];
    _set(_s.copyWith(conversations: updated));
    // Save the renamed conversation specifically (it may not be the active one).
    final r = renamed;
    if (r != null) {
      _persistSoon(
        _enqueueWrite(
          () => ref.read(conversationRepositoryProvider).saveConversation(r),
        ),
      );
    }
  }

  Future<void> deleteConversation(String id) async {
    // Deleting the conversation that is currently streaming: abort the stream
    // first, WITHOUT persisting it (a late save would resurrect the row).
    if (_s.streamingConvoId == id) stop(persist: false);

    // Remove it from memory before awaiting the database operation. The stream
    // teardown may resume as soon as stop() completes; _persistById then sees
    // no matching conversation and cannot enqueue a save behind this delete.
    final beforeDeletion = _s;
    final deletedIndex = beforeDeletion.conversations.indexWhere(
      (c) => c.id == id,
    );
    if (deletedIndex < 0) return;
    final deletedConversation = beforeDeletion.conversations[deletedIndex];
    final remaining = beforeDeletion.conversations
        .where((c) => c.id != id)
        .toList();
    final createsFreshConversation = remaining.isEmpty;
    final nextConversations = createsFreshConversation
        ? <Conversation>[Conversation()]
        : remaining;
    final nextCurrent = beforeDeletion.currentId == id
        ? nextConversations.first.id
        : beforeDeletion.currentId;
    _set(
      beforeDeletion.copyWith(
        conversations: nextConversations,
        currentId: nextCurrent,
        contextReports: {...beforeDeletion.contextReports}..remove(id),
        error: null,
      ),
    );

    try {
      await _deletePersistedConversation(id);
    } catch (e) {
      // Keep the archive visible if deleting its row failed, but do not restore
      // the entire old state: the user may have created or edited another
      // conversation while this awaited database write was in flight.
      if (ref.mounted) {
        final current = _s;
        final restored = current.conversations.any((c) => c.id == id)
            ? current.conversations
            : [
                ...current.conversations.take(deletedIndex),
                deletedConversation,
                ...current.conversations.skip(deletedIndex),
              ];
        _set(
          current.copyWith(
            conversations: restored,
            error: '本地删除失败：$e',
            errorConvoId: id,
          ),
        );
      }
      return;
    }

    if (createsFreshConversation) {
      _persistSoon(_persist());
    }
  }

  void stop({bool persist = true}) {
    // Also abort a generation that has been accepted but has not yet set
    // streamingConvoId (still awaiting settings / building the turn).
    _cancelStart = true;
    final streamingId = _s.streamingConvoId;
    final title = _titleFor(streamingId);
    _flushActiveStream?.call();
    _sub?.cancel();
    _sub = null;
    // Abort the underlying HTTP request too, so it stops consuming tokens.
    _cancelToken?.cancel();
    _cancelToken = null;
    final completer = _streamCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _streamCompleter = null;
    _set(
      _s.copyWith(
        streamingConvoId: null,
        isSearching: false,
        isGeneratingImage: false,
      ),
    );
    _signalIdleIfReady();
    if (persist && streamingId != null) _persistSoon(_persistById(streamingId));
    unawaited(
      GenerationNotify.onGenerationEnd(
        success: false,
        conversationTitle: title,
        cancelled: true,
      ),
    );
  }

  /// Stop the active or preflight generation and wait until its entry point has
  /// completely unwound. This prevents a replacement turn from being dropped
  /// by the synchronous [_starting] guard.
  Future<void> stopAndWait({bool persist = true}) async {
    if (!_starting && !_s.isStreaming) return;
    final idle = _idleCompleter ??= Completer<void>();
    stop(persist: persist);
    _signalIdleIfReady();
    await idle.future;
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

  /// Send a new user turn at the end of the active branch. Returns false when
  /// the send was rejected up front (empty input, already streaming, settings
  /// not ready) so the UI can restore the user's draft.
  Future<bool> sendMessage(
    String text, {
    List<Attachment> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && attachments.isEmpty) ||
        _s.isStreaming ||
        _starting) {
      return false;
    }
    _starting = true;
    _cancelStart = false;
    try {
      final convo = _s.current ?? Conversation();
      final hasImages =
          attachments.any((a) => a.isImage && a.hasImageData) ||
          convo.activePath.any(
            (m) =>
                m.role == MessageRole.user &&
                m.attachments.any((a) => a.isImage && a.hasImageData),
          );
      final requiresVision = attachments.any(
        (a) => a.isImage && a.hasImageData,
      );
      final settings = await _readySettingsForTurn(
        hasImages: hasImages,
        requireVision: requiresVision,
      );
      if (settings == null || _cancelStart) return false;
      final config = _configFor(
        settings,
        vision: hasImages && settings.visionConfigured,
      );

      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      final userMsg = ChatMessage(
        role: MessageRole.user,
        content: trimmed,
        attachments: attachments,
        parentId: parentId,
      );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: userMsg.id,
      );

      final isFirst = convo.messages.isEmpty;
      final titleSeed = trimmed.isNotEmpty
          ? trimmed
          : (attachments.isNotEmpty ? attachments.first.name : '新对话');
      final working = convo.copyWith(
        title: isFirst ? _truncateTitle(titleSeed) : convo.title,
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: {
          ...convo.activeChildren,
          parentId ?? kRootKey: userMsg.id,
          userMsg.id: assistantMsg.id,
        },
      );

      if (_cancelStart) return false;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: trimmed,
        thinking: _s.deepThink,
      );
      return true;
    } finally {
      _finishStarting();
    }
  }

  /// Grapheme-aware truncation so a 20-cut can't split an emoji/surrogate pair.
  static String _truncateTitle(String seed) {
    final chars = seed.characters;
    return chars.length > 20 ? '${chars.take(20)}…' : seed;
  }

  /// Edit a previous user message: creates a sibling under the same parent
  /// (keeping the old version as a branch) and regenerates from there.
  Future<void> editMessage(
    String messageId,
    String newText, {
    List<Attachment>? attachments,
  }) async {
    if (_s.isStreaming || _starting) return;
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;
    final convo = _s.current;
    if (convo == null) return;
    final oldIdx = convo.messages.indexWhere((m) => m.id == messageId);
    if (oldIdx < 0) return;
    final old = convo.messages[oldIdx];
    if (old.role != MessageRole.user) return;

    _starting = true;
    _cancelStart = false;
    try {
      final nextAttachments = attachments ?? old.attachments;
      // Only ancestors of the edited turn stay in the regenerated branch;
      // descendants (and their images) are discarded, so they must not pull
      // the request over to the vision endpoint.
      final ancestors = convo.activePath.takeWhile((m) => m.id != old.id);
      final hasImages =
          nextAttachments.any((a) => a.isImage && a.hasImageData) ||
          ancestors.any(
            (m) =>
                m.role == MessageRole.user &&
                m.attachments.any((a) => a.isImage && a.hasImageData),
          );
      final turnSettings = await _readySettingsForTurn(
        hasImages: hasImages,
        requireVision: nextAttachments.any((a) => a.isImage && a.hasImageData),
      );
      if (turnSettings == null || _cancelStart) return;
      final config = _configFor(
        turnSettings,
        vision: hasImages && turnSettings.visionConfigured,
      );

      final userMsg = ChatMessage(
        role: MessageRole.user,
        content: trimmed,
        attachments: nextAttachments,
        parentId: old.parentId,
      );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: userMsg.id,
      );
      final working = convo.copyWith(
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: {
          ...convo.activeChildren,
          old.parentId ?? kRootKey: userMsg.id,
          userMsg.id: assistantMsg.id,
        },
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: turnSettings,
        searchQuery: trimmed,
        thinking: _s.deepThink,
      );
    } finally {
      _finishStarting();
    }
  }

  /// Regenerate the last assistant reply as a NEW branch (the previous reply is
  /// kept and can be switched back to).
  Future<void> regenerate({ChatRetryOperation? retryOperation}) async {
    if (_s.isStreaming || _starting) return;
    final convo = _s.current;
    if (convo == null) return;

    ChatMessage? failedAssistant;
    List<ChatMessage> pathToUser;
    ChatMessage userMsg;
    if (retryOperation != null) {
      if (retryOperation.kind != ChatRetryKind.regenerate ||
          retryOperation.conversationId != convo.id) {
        return;
      }
      for (final message in convo.messages) {
        if (message.id == retryOperation.assistantMessageId &&
            message.role == MessageRole.assistant) {
          failedAssistant = message;
          break;
        }
      }
      final parentId = failedAssistant?.parentId;
      if (parentId == null) return;
      final path = _pathToMessage(convo, parentId);
      if (path.isEmpty || path.last.role != MessageRole.user) return;
      pathToUser = path;
      userMsg = path.last;
    } else {
      final path = convo.activePath;
      final lastUser = path.lastIndexWhere((m) => m.role == MessageRole.user);
      if (lastUser < 0) return;
      userMsg = path[lastUser];
      pathToUser = path.take(lastUser + 1).toList();
      failedAssistant =
          lastUser + 1 < path.length &&
              path[lastUser + 1].role == MessageRole.assistant
          ? path[lastUser + 1]
          : null;
    }

    // Plot-advance turns must keep advancePlot prompt semantics. If the first
    // attempt already succeeded, keep the persisted cursor and only override
    // the cursor used to assemble this prompt. Mutating the conversation itself
    // here made a successful rewrite permanently roll progress back one beat.
    final advanceCue = isPlotAdvanceUserContent(userMsg.content);
    int? promptPlotCursor = retryOperation?.promptPlotCursor;
    var commitAdvance = retryOperation?.commitPlotAdvance ?? false;
    final priorSucceeded =
        failedAssistant != null && failedAssistant.content.trim().isNotEmpty;
    if (retryOperation != null) {
      commitAdvance = retryOperation.commitPlotAdvance;
    } else if (advanceCue && convo.isStory) {
      if (priorSucceeded && convo.plotCursor > 0) {
        promptPlotCursor = convo.plotCursor - 1;
        commitAdvance = false;
      } else {
        commitAdvance = true;
      }
    }

    _starting = true;
    _cancelStart = false;
    try {
      final hasImages = pathToUser.any(
        (m) =>
            m.role == MessageRole.user &&
            m.attachments.any((a) => a.isImage && a.hasImageData),
      );
      final settings = await _readySettingsForTurn(hasImages: hasImages);
      if (settings == null || _cancelStart) return;
      final config = _configFor(
        settings,
        vision: hasImages && settings.visionConfigured,
      );

      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: userMsg.id,
      );
      final working = convo.copyWith(
        messages: [...convo.messages, assistantMsg],
        activeChildren: {
          ..._activatePath(convo.activeChildren, pathToUser),
          userMsg.id: assistantMsg.id,
        },
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: userMsg.content,
        thinking: _s.deepThink,
        advancePlot: advanceCue,
        promptPlotCursor: promptPlotCursor,
        commitPlotAdvance: commitAdvance,
      );
    } finally {
      _finishStarting();
    }
  }

  /// Switch which sibling branch is active at [messageId] (delta -1 / +1).
  void switchBranch(String messageId, int delta) {
    if (_s.isStreaming) return;
    final convo = _s.current;
    if (convo == null) return;
    final mIdx = convo.messages.indexWhere((x) => x.id == messageId);
    if (mIdx < 0) return;
    final m = convo.messages[mIdx];
    final key = m.parentId ?? kRootKey;
    final sibs = convo.childrenOf(key);
    if (sibs.length < 2) return;
    final curIdx = sibs.indexWhere((x) => x.id == messageId);
    final newIdx = (curIdx + delta).clamp(0, sibs.length - 1);
    if (newIdx == curIdx) return;
    _set(
      _s.copyWith(
        conversations: _replace(
          convo.copyWith(
            activeChildren: {...convo.activeChildren, key: sibs[newIdx].id},
          ),
        ),
      ),
    );

    _persistSoon(_persist());
  }

  /// Replay the exact failed operation represented by the error banner.
  Future<void> retryLast() async {
    final operation = _s.retryOperation;
    if (operation == null) return;
    if (operation.conversationId != _s.currentId) {
      if (!_s.conversations.any((c) => c.id == operation.conversationId)) {
        return;
      }
      selectConversation(operation.conversationId);
    }
    switch (operation.kind) {
      case ChatRetryKind.regenerate:
        await regenerate(retryOperation: operation);
      case ChatRetryKind.image:
        await _retryGeneratedImage(operation);
      case ChatRetryKind.ensemble:
        await _retryEnsemble(operation);
    }
  }

  Future<void> _retryGeneratedImage(ChatRetryOperation operation) async {
    if (_s.isStreaming || _starting) return;
    final convo = _s.current;
    if (convo == null || convo.id != operation.conversationId) return;
    ChatMessage? failedAssistant;
    for (final message in convo.messages) {
      if (message.id == operation.assistantMessageId &&
          message.role == MessageRole.assistant &&
          message.kind == MessageKind.generatedImage) {
        failedAssistant = message;
        break;
      }
    }
    final userId = failedAssistant?.parentId;
    if (userId == null) return;
    ChatMessage? userMessage;
    for (final message in convo.messages) {
      if (message.id == userId && message.role == MessageRole.user) {
        userMessage = message;
        break;
      }
    }
    if (userMessage == null) return;
    await _generateImageTurn(
      userMessage.content,
      referenceImages: userMessage.attachments,
      existingUserMessageId: userMessage.id,
    );
  }

  Future<void> _retryEnsemble(ChatRetryOperation operation) async {
    if (_s.isStreaming || _starting) return;
    final convo = _s.current;
    if (convo == null ||
        convo.id != operation.conversationId ||
        !convo.isEnsemble) {
      return;
    }
    ChatMessage? failedAssistant;
    for (final message in convo.messages) {
      if (message.id == operation.assistantMessageId &&
          message.role == MessageRole.assistant) {
        failedAssistant = message;
        break;
      }
    }
    final speakerId = operation.ensembleSpeakerId ?? failedAssistant?.speakerId;
    if (failedAssistant == null || speakerId == null) return;

    _starting = true;
    _cancelStart = false;
    try {
      final card = await ref
          .read(characterRepositoryProvider)
          .getById(speakerId);
      if (card == null || _cancelStart) {
        if (card == null) {
          _set(_s.copyWith(error: '找不到角色卡，请检查参与名单。'));
        }
        return;
      }
      final settings = await _readySettings();
      if (settings == null || _cancelStart) return;
      final config = _configFor(settings);
      final parentId = failedAssistant.parentId;
      final pathToParent = parentId == null
          ? const <ChatMessage>[]
          : _pathToMessage(convo, parentId);
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: parentId,
        speakerId: card.id,
        speakerName: card.name,
      );
      final working = convo.copyWith(
        messages: [...convo.messages, assistantMsg],
        activeChildren: {
          ..._activatePath(convo.activeChildren, pathToParent),
          parentId ?? kRootKey: assistantMsg.id,
        },
      );
      if (_cancelStart) return;
      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: '',
        thinking: _s.deepThink,
        ensembleSpeaker: card,
      );
    } finally {
      _finishStarting();
    }
  }

  /// Generate an image as a normal conversation turn. This endpoint is wholly
  /// optional and does not depend on the main chat provider being configured
  /// — unless [ChatState.deepThink] is on, in which case the chat/reasoner
  /// model first rewrites the prompt, then the result is sent to the image API.
  ///
  /// When [referenceImages] contains an image with data, the request uses the
  /// OpenAI-compatible `/images/edits` (图生图) path; otherwise text-to-image.
  Future<bool> generateImage(
    String prompt, {
    List<Attachment> referenceImages = const [],
  }) => _generateImageTurn(prompt, referenceImages: referenceImages);

  Future<bool> _generateImageTurn(
    String prompt, {
    List<Attachment> referenceImages = const [],
    String? existingUserMessageId,
  }) async {
    final trimmed = prompt.trim();
    final refs = [
      for (final a in referenceImages)
        if (a.isImage && a.hasImageData) a,
    ];
    if (trimmed.isEmpty || _s.isStreaming || _starting) return false;
    _starting = true;
    _cancelStart = false;
    try {
      final settings = await ref.read(settingsControllerProvider.future);
      if (!settings.imageGenerationConfigured) {
        _set(_s.copyWith(error: '请先在设置中完整配置图片生成 API。'));
        return false;
      }
      final useDeepThink = _s.deepThink;
      if (useDeepThink && !settings.config.isReady) {
        _set(_s.copyWith(error: '深度思考生图需要先配置对话 API（用于优化提示词）。'));
        return false;
      }
      if (_cancelStart) return false;

      // Edits APIs typically take one source image; extra refs are ignored.
      final reference = refs.isEmpty ? null : refs.first;

      final convo = _s.current ?? Conversation();
      ChatMessage? existingUser;
      if (existingUserMessageId != null) {
        for (final message in convo.messages) {
          if (message.id == existingUserMessageId &&
              message.role == MessageRole.user) {
            existingUser = message;
            break;
          }
        }
        if (existingUser == null) return false;
      }
      final parentId =
          existingUser?.parentId ??
          (convo.activePath.isEmpty ? null : convo.activePath.last.id);
      final userMsg =
          existingUser ??
          ChatMessage(
            role: MessageRole.user,
            content: trimmed,
            parentId: parentId,
            attachments: reference == null ? const [] : [reference],
          );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: useDeepThink
            ? settings.reasonerModel
            : settings.imageGenerationApi.model,
        kind: MessageKind.generatedImage,
        parentId: userMsg.id,
      );
      final isFirst = existingUser == null && convo.messages.isEmpty;
      final pathToUser = existingUser == null
          ? const <ChatMessage>[]
          : _pathToMessage(convo, existingUser.id);
      final working = convo.copyWith(
        title: isFirst ? _truncateTitle(trimmed) : convo.title,
        messages: [
          ...convo.messages,
          if (existingUser == null) userMsg,
          assistantMsg,
        ],
        activeChildren: {
          ..._activatePath(convo.activeChildren, pathToUser),
          if (existingUser == null) parentId ?? kRootKey: userMsg.id,
          userMsg.id: assistantMsg.id,
        },
      );
      final failureOperation = ChatRetryOperation(
        kind: ChatRetryKind.image,
        conversationId: working.id,
        assistantMessageId: assistantMsg.id,
      );
      final cancelToken = CancelToken();
      _cancelToken = cancelToken;
      _set(
        _s.copyWith(
          conversations: [
            working,
            ..._s.conversations.where((c) => c.id != working.id),
          ],
          currentId: working.id,
          streamingConvoId: working.id,
          isSearching: false,
          isGeneratingImage: false,
          error: null,
        ),
      );
      unawaited(GenerationNotify.onGenerationStart());
      try {
        await _persistById(working.id);
      } catch (e) {
        // Same contract as _generate: a transient local-storage failure must
        // not abort the turn (and must never strand streamingConvoId); the
        // final/checkpoint writes below retry through the serialized queue.
        _setScopedError('本地保存失败：$e', convoId: working.id);
      }

      try {
        var imagePrompt = trimmed;
        var optimizedByModel = '';
        var reasoning = '';
        var thinkingMillis = 0;

        if (useDeepThink) {
          final refined = await _optimizeImagePrompt(
            userPrompt: trimmed,
            settings: settings,
            cancelToken: cancelToken,
            onReasoning: (text, millis) {
              reasoning = text;
              thinkingMillis = millis;
              _updateAssistant(
                working.id,
                assistantMsg.id,
                '',
                reasoning,
                thinkingMillis,
              );
            },
          );
          if (!_s.isStreaming || cancelToken.isCancelled) {
            await _persistById(working.id);
            unawaited(
              GenerationNotify.onGenerationEnd(
                success: false,
                conversationTitle: working.title,
                cancelled: true,
              ),
            );
            return true;
          }
          optimizedByModel = refined;
          if (refined.isNotEmpty) imagePrompt = refined;
          _updateAssistant(
            working.id,
            assistantMsg.id,
            '正在生成图片…',
            reasoning,
            thinkingMillis,
          );
        }

        // Align pure 生图 with dialogue illustration: scrub NSFW phrasing and
        // append an SFW suffix before hitting the media API.
        imagePrompt = ImagePromptSafety.freeform(imagePrompt);

        List<int>? refBytes;
        var refMime = 'image/png';
        var refName = 'reference.png';
        if (reference != null) {
          final b64 = reference.imageBase64;
          if (b64 != null && b64.isNotEmpty) {
            try {
              // Large phone photos: decode base64 off the UI isolate, then
              // downscale on the UI isolate (target-bound decode that never
              // materialises the full-size buffer). References picked through
              // the composer are already pre-scaled, so this is usually a
              // no-op; it stays as a fallback for non-picker sources.
              final raw = b64.length >= 256 * 1024
                  ? await compute(base64Decode, b64)
                  : base64Decode(b64);
              final prepared = await ImageCodecUtil.prepareReferenceImage(
                Uint8List.fromList(raw),
                mimeType: reference.mimeType,
                name: reference.name,
              );
              refBytes = prepared.bytes;
              refMime = prepared.mimeType;
              refName = prepared.name;
            } on FormatException {
              _setScopedError(
                '参考图数据无效，请重新选择图片。',
                convoId: working.id,
                retryOperation: failureOperation,
              );
              _set(_s.copyWith(streamingConvoId: null));
              await _persistById(working.id);
              unawaited(
                GenerationNotify.onGenerationEnd(
                  success: false,
                  conversationTitle: working.title,
                ),
              );
              return true;
            }
          } else {
            _set(
              _s.copyWith(
                error: '参考图缺少本地数据，请重新从相册/文件选择图片。',
                errorConvoId: working.id,
                retryOperation: failureOperation,
                streamingConvoId: null,
              ),
            );
            await _persistById(working.id);
            unawaited(
              GenerationNotify.onGenerationEnd(
                success: false,
                conversationTitle: working.title,
              ),
            );
            return true;
          }
        }

        if (_s.isStreaming) {
          _set(_s.copyWith(isGeneratingImage: true, isSearching: false));
        }
        final generated = await ref
            .read(mediaApiProvider)
            .generateImage(
              config: settings.imageGenerationApi,
              apiKey: settings.imageGenerationApiKey,
              prompt: imagePrompt,
              cancelToken: cancelToken,
              referenceImageBytes: refBytes,
              referenceMimeType: refMime,
              referenceFileName: refName,
            );
        if (!_s.isStreaming || cancelToken.isCancelled) {
          await _persistById(working.id);
          unawaited(
            GenerationNotify.onGenerationEnd(
              success: false,
              conversationTitle: working.title,
              cancelled: true,
            ),
          );
          return true;
        }
        final sizeBytes = generated.base64 == null
            ? 0
            : (generated.base64!.length * 3 / 4).round();
        final attachment = Attachment(
          name: 'generated-${DateTime.now().millisecondsSinceEpoch}.png',
          mimeType: generated.mimeType,
          sizeBytes: sizeBytes,
          imageBase64: generated.base64,
          remoteUrl: generated.remoteUrl,
        );
        final content = _imageGenResultContent(
          originalPrompt: trimmed,
          optimizedByModel: optimizedByModel,
          revisedByApi: generated.revisedPrompt,
          usedReferenceImage: reference != null,
        );
        _updateGeneratedImage(
          working.id,
          assistantMsg.id,
          content: content,
          attachment: attachment,
          reasoning: reasoning,
          thinkingMillis: thinkingMillis,
          model: settings.imageGenerationApi.model,
        );
        _set(
          _s.copyWith(
            streamingConvoId: null,
            isGeneratingImage: false,
            error: null,
          ),
        );
        await _persistById(working.id);
        unawaited(
          GenerationNotify.onGenerationEnd(
            success: true,
            conversationTitle: working.title,
            preview: '图片已生成',
          ),
        );
        return true;
      } catch (e) {
        final cancelled = e is DioException && CancelToken.isCancel(e);
        if (!cancelled) {
          _set(
            _s.copyWith(
              streamingConvoId: null,
              isGeneratingImage: false,
              error: _describeError(e),
              errorConvoId: working.id,
              retryOperation: failureOperation,
            ),
          );
        } else {
          _set(_s.copyWith(isGeneratingImage: false));
        }
        await _persistById(working.id);
        unawaited(
          GenerationNotify.onGenerationEnd(
            success: false,
            conversationTitle: working.title,
            cancelled: cancelled,
          ),
        );
        return true;
      } finally {
        if (_s.isGeneratingImage) {
          _set(_s.copyWith(isGeneratingImage: false));
        }
        if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      }
    } finally {
      _finishStarting();
    }
  }

  /// Uses the deep-think / reasoner model to rewrite [userPrompt] into a
  /// stronger text-to-image prompt. Returns the cleaned prompt text (may be
  /// empty if the model returned nothing useful — caller falls back to raw).
  Future<String> _optimizeImagePrompt({
    required String userPrompt,
    required SettingsState settings,
    required CancelToken cancelToken,
    required void Function(String reasoning, int thinkingMillis) onReasoning,
  }) async {
    final config = _configFor(settings);
    final llm = ref.read(llmProvider);
    final contentBuf = StringBuffer();
    final reasoningBuf = StringBuffer();
    final sw = Stopwatch();
    await for (final chunk in llm.streamChat(
      config: config,
      thinking: true,
      cancelToken: cancelToken,
      messages: [
        const LlmRequestMessage(
          role: MessageRole.system,
          content: _kImagePromptOptimizerSystem,
        ),
        LlmRequestMessage(role: MessageRole.user, content: userPrompt),
      ],
    )) {
      if (cancelToken.isCancelled) break;
      if (chunk.reasoningDelta != null && chunk.reasoningDelta!.isNotEmpty) {
        if (!sw.isRunning) sw.start();
        reasoningBuf.write(chunk.reasoningDelta);
        onReasoning(reasoningBuf.toString(), sw.elapsedMilliseconds);
      }
      if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
        if (sw.isRunning) sw.stop();
        contentBuf.write(chunk.contentDelta);
      }
    }
    if (sw.isRunning) sw.stop();
    if (reasoningBuf.isNotEmpty) {
      onReasoning(reasoningBuf.toString(), sw.elapsedMilliseconds);
    }
    return _cleanOptimizedImagePrompt(contentBuf.toString());
  }

  static const _kImagePromptOptimizerSystem =
      '你是文生图提示词优化助手。用户会给出简短、口语化或中文的画面描述。'
      '请改写成高质量的文生图提示词：补全主体、场景、构图、光影、材质、风格与细节，'
      '尽量使用英文（专有名词/书法文字可保留原文），适合常见文生图模型。'
      '只输出最终提示词本身，不要解释、不要标题、不要引号或代码块围栏。';

  /// Strip common model decorations so the image API gets a clean prompt.
  static String _cleanOptimizedImagePrompt(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    // ```lang ... ``` or ``` ... ```
    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$', multiLine: true);
    final m = fence.firstMatch(text);
    if (m != null) text = (m.group(1) ?? '').trim();
    // Surrounding quotes.
    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'")) ||
        (text.startsWith('“') && text.endsWith('”'))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  static String _imageGenResultContent({
    required String originalPrompt,
    required String optimizedByModel,
    String? revisedByApi,
    bool usedReferenceImage = false,
  }) {
    final parts = <String>[usedReferenceImage ? '图片已生成（图生图）' : '图片已生成'];
    final opt = optimizedByModel.trim();
    final revised = revisedByApi?.trim() ?? '';
    if (opt.isNotEmpty && opt != originalPrompt.trim()) {
      parts.add('深度思考优化后的提示词：$opt');
    }
    if (revised.isNotEmpty &&
        revised != opt &&
        revised != originalPrompt.trim()) {
      parts.add('生图接口改写：$revised');
    }
    if (parts.length == 1 && revised.isNotEmpty) {
      parts.add('优化后的提示词：$revised');
    }
    return parts.join('\n\n');
  }

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
    required bool hasImages,
    bool requireVision = false,
  }) async {
    final settings = await ref.read(settingsControllerProvider.future);
    if (hasImages && settings.visionConfigured) return settings;
    if (requireVision) {
      _set(_s.copyWith(error: '图片消息需要先在设置中完整配置视觉 API。'));
      return null;
    }
    if (!settings.config.isReady) {
      _set(_s.copyWith(error: '请先在设置中填写 API Key。'));
      return null;
    }
    return settings;
  }

  /// The deep-think toggle routes to the active profile's reasoner model.
  LlmConfig _configFor(SettingsState settings, {bool vision = false}) => vision
      ? settings.visionConfig
      : _s.deepThink
      ? settings.config.copyWith(model: settings.reasonerModel)
      : settings.config;

  /// Shared pipeline: show the pending turn, optionally expose `web_search` as
  /// a model-controlled tool, then stream the answer along the active branch.
  ///
  /// [advancePlot] shapes the director/story prompt ("推进情节").
  /// [promptPlotCursor] can rewrite an already-committed beat without mutating
  /// the conversation's persisted progress.
  /// [commitPlotAdvance] increments [Conversation.plotCursor] after success;
  /// regenerate of an already-advanced turn must pass false to avoid double
  /// cursor bumps and wrong-beat rewrites.
  Future<void> _generate({
    required Conversation working,
    required String assistantId,
    required LlmConfig config,
    required SettingsState settings,
    required String searchQuery,
    required bool thinking,
    bool advancePlot = false,
    int? promptPlotCursor,
    bool commitPlotAdvance = false,
    CharacterCard? ensembleSpeaker,
  }) async {
    final searchMode = _s.searchMode;
    final searchAllowed =
        searchMode != SearchMode.off && searchQuery.trim().isNotEmpty;
    final useWebSearchTool = searchAllowed && config.capabilities.supportsTools;
    // Only expose direct page fetching when this turn actually contains a URL.
    // The executor also restricts calls to this exact allow-list so a model
    // cannot invent unrelated network targets while "联网" is off.
    final pastedUrls = extractHttpUrls(searchQuery);
    // Browser clients cannot safely pin DNS and arbitrary pages are normally
    // CORS-blocked. Until a trusted fetch proxy exists, keep direct fetch off.
    final directPageFetchAllowed = !kIsWeb;
    final useFetchUrlTool =
        directPageFetchAllowed &&
        pastedUrls.isNotEmpty &&
        config.capabilities.supportsTools;
    // Dialogue 配图 (not pure 生图 mode): auto exposes the tool; always also
    // pre-generates one image so force works on tool-less reasoners.
    final imageGenMode = _s.imageGenMode;
    final imageGenConfigured = settings.imageGenerationConfigured;
    final imageGenWanted =
        imageGenMode != ImageGenMode.off && imageGenConfigured;
    final toolSpecs = <ToolSpec>[
      if (useWebSearchTool) ToolEngine.webSearchTool,
      if (useFetchUrlTool) ToolEngine.fetchUrlTool,
    ];
    final allowedFetchUrls = {for (final url in pastedUrls) _fetchUrlKey(url)};
    final imageBudget = _TurnImageBudget();
    final failureOperation = ChatRetryOperation(
      kind: ensembleSpeaker == null
          ? ChatRetryKind.regenerate
          : ChatRetryKind.ensemble,
      conversationId: working.id,
      assistantMessageId: assistantId,
      promptPlotCursor: promptPlotCursor,
      commitPlotAdvance: commitPlotAdvance,
      ensembleSpeakerId: ensembleSpeaker?.id,
    );

    // One token covers the whole generation (search pre-step + all tool
    // rounds); stop() fires it.
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    _set(
      _s.copyWith(
        // Move the conversation to the top: it just got new activity, matching
        // the updatedAt-desc order used when loading from the DB. Also covers
        // the defensive case where [working] wasn't in the list yet.
        conversations: [
          working,
          ..._s.conversations.where((c) => c.id != working.id),
        ],
        currentId: working.id,
        streamingConvoId: working.id,
        isSearching: false,
        isGeneratingImage: false,
        error: null,
      ),
    );
    // Keep the device awake and allow a completion notification if the user
    // backgrounds the app mid-generation.
    unawaited(GenerationNotify.onGenerationStart());

    // Write the user turn and assistant placeholder before any network work.
    // If the app is backgrounded or killed during a long response, the turn is
    // still recoverable on the next launch.
    try {
      await _persistById(working.id);
    } catch (e) {
      // Don't crash the send action on a transient local-storage failure. The
      // final/checkpoint writes will retry through the serialized queue, while
      // the user gets a visible diagnostic instead of losing the live reply.
      _setScopedError('本地保存失败：$e', convoId: working.id);
    }

    // Resolve which character (if any) owns this turn's portrait target.
    final imageCharacter = await _resolveImageCharacter(
      working,
      ensembleSpeaker: ensembleSpeaker,
    );

    // Pre-steps that inject context before the model answers:
    // 1) fetch any URLs the user pasted (works with or without "联网")
    // 2) planner-orchestrated web search for models that cannot use tools
    //    (deepseek-reasoner…), and for tool models when "联网·强制" is on —
    //    which guarantees at least one search before the answer starts.
    // 3) 配图·强制: one SFW image (character portrait when a card is bound).
    SearchContext? searchContext;
    var forceImageNote = '';
    if (imageGenWanted &&
        imageGenMode == ImageGenMode.always &&
        imageBudget.canGenerate &&
        _s.isStreaming) {
      final pre = await _runDialogueImageGeneration(
        settings: settings,
        convoId: working.id,
        assistantId: assistantId,
        character: imageCharacter,
        userText: searchQuery,
        modelPrompt: null,
        briefHint: null,
        cancelToken: cancelToken,
        optimizeWithDeepThink: _s.deepThink,
      );
      if (pre.ok) {
        imageBudget.markUsed();
        forceImageNote = imageCharacter != null
            ? '本轮已为角色「${imageCharacter.name}」生成一张安全立绘配图，请结合该形象回答，无需再调用生图。'
            : '本轮已生成一张安全配图并附在回复中，请结合配图回答，无需再调用生图。';
      } else if (pre.error != null && pre.error!.isNotEmpty && _s.isStreaming) {
        _setScopedError(pre.error!, convoId: working.id);
      }
    }
    // Auto: model may call once. Always: tool only if pre-gen still has budget
    // (e.g. pre-gen failed) so force can still succeed via function calling.
    final useImageGenTool =
        imageGenWanted &&
        imageBudget.canGenerate &&
        config.capabilities.supportsTools &&
        (imageGenMode == ImageGenMode.auto ||
            imageGenMode == ImageGenMode.always);
    if (useImageGenTool) {
      toolSpecs.add(ToolEngine.generateImageTool);
    }
    final enableTools = toolSpecs.isNotEmpty;
    // Tool-capable models can decide when the pasted link is relevant. Models
    // without function calling keep the deterministic pre-fetch fallback.
    final needPreFetch =
        directPageFetchAllowed && pastedUrls.isNotEmpty && !useFetchUrlTool;
    final needPreSearch =
        searchAllowed && (!useWebSearchTool || searchMode == SearchMode.always);
    if (needPreFetch || needPreSearch) {
      _set(_s.copyWith(isSearching: true, isGeneratingImage: false));
      // Live progress steps land on the assistant placeholder as they happen.
      void activitySink(SearchActivity activity) =>
          _upsertSearchActivity(working.id, assistantId, activity);
      try {
        final engine = ref.read(toolEngineFactoryProvider)(
          backend: settings.searchBackend,
          apiKey: settings.searchApiKey,
        );
        final citations = <Citation>[];
        final blocks = <String>[];

        if (needPreFetch) {
          final fetched = await engine.runFetchUrls(
            pastedUrls,
            startIndex: 1,
            onActivity: activitySink,
            cancelToken: cancelToken,
          );
          if (fetched.citations.isNotEmpty) {
            citations.addAll(fetched.citations);
            blocks.add(fetched.contextText);
          }
        }

        if (needPreSearch) {
          final orchestration = await _runOrchestratedSearch(
            engine: engine,
            settings: settings,
            working: working,
            assistantId: assistantId,
            searchQuery: searchQuery,
            force: searchMode == SearchMode.always,
            startIndex: citations.length + 1,
            onActivity: activitySink,
            cancelToken: cancelToken,
          );
          if (orchestration.context.citations.isNotEmpty) {
            citations.addAll(orchestration.context.citations);
            blocks.add(orchestration.context.contextText);
          }
        }

        if (citations.isNotEmpty) {
          searchContext = SearchContext(
            contextText: blocks.join('\n'),
            citations: List.unmodifiable(citations),
          );
          _setCitations(working.id, assistantId, searchContext.citations);
        }
      } catch (e) {
        // Stop pressed during the search/fetch is not an error.
        if (!_isCancel(e)) {
          _setScopedError(_describeError(e), convoId: working.id);
        }
      } finally {
        _set(_s.copyWith(isSearching: false, isGeneratingImage: false));
      }
    }

    // The user may have pressed stop during the (awaited) search; honor it.
    if (!_s.isStreaming) {
      await _persistById(working.id);
      // stop() already ends the notify session when the user pressed stop;
      // still clear wakelock if streaming dropped for another reason.
      unawaited(
        GenerationNotify.onGenerationEnd(
          success: false,
          conversationTitle: working.title,
          cancelled: _cancelStart,
        ),
      );
      return;
    }

    // Build the request from the CURRENT active branch (re-read state, since
    // citations may have replaced the conversation object), excluding the empty
    // assistant placeholder and expanding attachments into text.
    final cur = _s.conversations.firstWhere(
      (c) => c.id == working.id,
      orElse: () => working,
    );
    var memoryPrompt = '';
    if (settings.memoryEnabled) {
      try {
        final recall = await ref
            .read(memoryRepositoryProvider)
            .recall(searchQuery, maxItems: 8, maxChars: 4000);
        memoryPrompt = recall.toSystemPrompt();
      } catch (_) {
        // Long-term memory is optional context. A damaged/unavailable local
        // memory file must never prevent the user from sending a message.
      }
    }
    final vision = config.capabilities.supportsVision;
    final history = cur.activePath
        .where((m) => m.id != assistantId)
        .map((m) => _toRequestMessage(m, vision: vision))
        .toList();

    if (searchContext != null && searchContext.contextText.isNotEmpty) {
      final insertAt = history.isEmpty ? 0 : history.length - 1;
      history.insert(
        insertAt,
        LlmRequestMessage(
          role: MessageRole.system,
          content: searchContext.contextText,
        ),
      );
    }

    // System prefix: story / ensemble use the assembler; chat keeps global only.
    if (cur.isStoryLike) {
      final worldPool = cur.worldInfoIds.isEmpty
          ? const <WorldInfoEntry>[]
          : await ref
                .read(worldInfoRepositoryProvider)
                .loadByIds(cur.worldInfoIds);
      final pathForScan = cur.activePath
          .where((m) => m.id != assistantId)
          .toList();

      CharacterCard? card;
      var cast = const <CharacterCard>[];
      final ensemble = cur.isEnsemble && ensembleSpeaker != null;
      final directorStory = cur.isStory && cur.localCast.isNotEmpty;
      if (directorStory) {
        cast = cur.localCast;
      } else if (ensemble) {
        final loaded = <CharacterCard>[];
        for (final id in cur.castIds) {
          final c = await ref.read(characterRepositoryProvider).getById(id);
          if (c != null) loaded.add(c);
        }
        cast = loaded;
        card = ensembleSpeaker;
      } else if (cur.characterId != null) {
        card = await ref
            .read(characterRepositoryProvider)
            .getById(cur.characterId!);
      }

      // Rewrite history so ensemble lines are labeled by speaker for the model.
      if (ensemble) {
        final labeled = <LlmRequestMessage>[];
        for (final m in pathForScan) {
          if (m.role == MessageRole.assistant &&
              (m.speakerName ?? '').isNotEmpty) {
            labeled.add(
              LlmRequestMessage(
                role: MessageRole.assistant,
                content: '【${m.speakerName}】${m.content}',
              ),
            );
          } else {
            labeled.add(_toRequestMessage(m, vision: vision));
          }
        }
        history
          ..clear()
          ..addAll(labeled);
        if (searchContext != null && searchContext.contextText.isNotEmpty) {
          final insertAt = history.isEmpty ? 0 : history.length - 1;
          history.insert(
            insertAt,
            LlmRequestMessage(
              role: MessageRole.system,
              content: searchContext.contextText,
            ),
          );
        }
      }

      final promptConversation = promptPlotCursor == null
          ? cur
          : cur.copyWith(plotCursor: promptPlotCursor);
      final prefix = const StoryPromptAssembler().buildSystemPrefix(
        globalSystemPrompt: settings.systemPrompt,
        character: card,
        cast: cast,
        speakingAs: ensembleSpeaker,
        worldInfoPool: worldPool,
        conversation: promptConversation,
        historyPath: pathForScan,
        advancePlot: advancePlot,
        ensembleTurn: ensemble,
        directorMode: directorStory,
      );
      if (prefix.worldInfoHits.isNotEmpty) {
        _setAppliedWorldInfo(working.id, assistantId, prefix.worldInfoHits);
      }
      // System order: story/director hard blocks first, then lower-priority
      // notes (force-image, tools). Never insert tools at index 0 ahead of
      // 【硬性导演说明】.
      final systemPrefix = <LlmRequestMessage>[...prefix.messages];
      if (memoryPrompt.isNotEmpty) {
        systemPrefix.add(
          LlmRequestMessage(role: MessageRole.system, content: memoryPrompt),
        );
      }
      if (forceImageNote.isNotEmpty) {
        systemPrefix.add(
          LlmRequestMessage(role: MessageRole.system, content: forceImageNote),
        );
      }
      if (enableTools) {
        final hint = StringBuffer(ToolEngine.dateLine())..write('。');
        if (useWebSearchTool) {
          hint.write(
            '需要实时、最新或不确定的事实信息时，优先调用 web_search；'
            '搜索关键词应自包含（把指代替换成具体名称，时效性问题带上年份）。',
          );
        }
        if (useFetchUrlTool) {
          hint.write('用户在本轮消息中给出的链接可用 fetch_url 读取。');
        }
        if (useImageGenTool) {
          if (imageCharacter != null) {
            hint.write(
              '需要为角色「${imageCharacter.name}」配安全立绘时调用 generate_image（每轮最多一次）；'
              '即使用户在写成人向内容，生图也只画干净角色形象，禁止色情提示词。',
            );
          } else {
            hint.write('需要配图时调用 generate_image（每轮最多一次）；提示词必须 SFW，禁止色情内容。');
          }
        }
        systemPrefix.add(
          LlmRequestMessage(role: MessageRole.system, content: hint.toString()),
        );
      }
      history.insertAll(0, systemPrefix);
    } else {
      if (memoryPrompt.isNotEmpty) {
        history.insert(
          0,
          LlmRequestMessage(role: MessageRole.system, content: memoryPrompt),
        );
      }
      final preset = settings.systemPrompt.trim();
      if (preset.isNotEmpty) {
        history.insert(
          0,
          LlmRequestMessage(role: MessageRole.system, content: preset),
        );
      }
      if (forceImageNote.isNotEmpty) {
        history.insert(
          0,
          LlmRequestMessage(role: MessageRole.system, content: forceImageNote),
        );
      }
      if (enableTools) {
        // Ground tool-capable models in "now" so time-sensitive queries carry a
        // year, and spell out when each tool applies.
        final hint = StringBuffer(ToolEngine.dateLine())..write('。');
        if (useWebSearchTool) {
          hint.write(
            '需要实时、最新或不确定的事实信息时，优先调用 web_search；'
            '搜索关键词应自包含（把指代替换成具体名称，时效性问题带上年份）。',
          );
        }
        if (useFetchUrlTool) {
          hint.write('用户在本轮消息中给出的链接可用 fetch_url 读取。');
        }
        if (useImageGenTool) {
          if (imageCharacter != null) {
            hint.write(
              '需要为角色「${imageCharacter.name}」配安全立绘时调用 generate_image（每轮最多一次）；'
              '即使用户在写成人向内容，生图也只画干净角色形象，禁止色情提示词。',
            );
          } else {
            hint.write('需要配图时调用 generate_image（每轮最多一次）；提示词必须 SFW，禁止色情内容。');
          }
        }
        history.insert(
          0,
          LlmRequestMessage(role: MessageRole.system, content: hint.toString()),
        );
      }
    }

    if (!_s.isStreaming) {
      await _persistById(working.id);
      return;
    }

    final contextResult = ref
        .read(contextWindowManagerProvider)
        .manage(history, settings.context);
    _recordContextReport(working.id, contextResult.report);
    if (settings.context.enabled &&
        contextResult.report.sentTokens >
            contextResult.report.inputBudgetTokens) {
      _set(
        _s.copyWith(
          streamingConvoId: null,
          error: '当前消息和图片超过上下文预算，请减少附件或在设置中增大上下文窗口。',
          errorConvoId: working.id,
          retryOperation: failureOperation,
        ),
      );
      await _persistById(working.id);
      unawaited(
        GenerationNotify.onGenerationEnd(
          success: false,
          conversationTitle: working.title,
        ),
      );
      return;
    }

    final succeeded = await _streamAnswer(
      config: config,
      history: contextResult.messages,
      convoId: working.id,
      assistantId: assistantId,
      thinking: thinking,
      settings: settings,
      fallbackSearchQuery: searchQuery,
      enableTools: enableTools,
      toolSpecs: toolSpecs,
      initialCitations: searchContext?.citations ?? const <Citation>[],
      allowedFetchUrls: Set<String>.unmodifiable(allowedFetchUrls),
      cancelToken: cancelToken,
      imageBudget: imageBudget,
      imageCharacter: imageCharacter,
      failureOperation: failureOperation,
    );

    unawaited(
      GenerationNotify.onGenerationEnd(
        success: succeeded,
        conversationTitle: working.title,
        preview: _previewFor(working.id, assistantId),
        cancelled: !succeeded && _cancelStart,
      ),
    );

    // Auto-advance only after a successful first advance (not regenerate of an
    // already-committed beat). With a total-length target, one generated
    // section is intentionally only part of a beat, so keep the cursor on the
    // same beat until its cumulative character threshold is reached.
    if (succeeded && commitPlotAdvance && cur.isStory) {
      final latest = _s.conversations.firstWhere(
        (c) => c.id == working.id,
        orElse: () => cur,
      );
      if (latest.isStory) {
        final beats = latest.outlineBeats;
        final lengthBudget = StoryLengthBudget.forConversation(latest);
        final shouldAdvance =
            lengthBudget == null ||
            beats.isEmpty ||
            lengthBudget.currentBeatTargetReached;
        final next = shouldAdvance
            ? (beats.isEmpty
                  ? latest.plotCursor + 1
                  : (latest.plotCursor + 1).clamp(0, beats.length))
            : latest.plotCursor;
        final updated = latest.copyWith(plotCursor: next);
        _set(_s.copyWith(conversations: _replace(updated)));
        await _persistById(working.id);
      }
    }
  }

  /// True when [e] is a cancellation raised by stop() firing the CancelToken.
  static bool _isCancel(Object e) =>
      e is DioException && CancelToken.isCancel(e);

  /// Error-banner text for a caught throwable.
  ///
  /// `Exception`s carry messages written for users, so the message survives as
  /// written - only the bare `Exception: ` prefix that `toString()` bolts on is
  /// dropped. An `Error` is always a bug and often stringifies to something
  /// with no diagnostic value at all - `StackOverflowError` is literally
  /// "Stack Overflow", which cost a full debugging session to trace back to a
  /// regexp - so those get their type appended.
  static String _describeError(Object e) {
    final text = e.toString();
    if (text.startsWith('Exception: ')) return text.substring(11);
    return e is Exception ? text : '$text（${e.runtimeType}）';
  }

  /// Returns true when the stream finished with an answer (not cancelled/errored).
  Future<bool> _streamAnswer({
    required LlmConfig config,
    required List<LlmRequestMessage> history,
    required String convoId,
    required String assistantId,
    required bool thinking,
    required SettingsState settings,
    required String fallbackSearchQuery,
    required bool enableTools,
    required List<ToolSpec> toolSpecs,
    required List<Citation> initialCitations,
    required Set<String> allowedFetchUrls,
    required CancelToken cancelToken,
    required _TurnImageBudget imageBudget,
    required ChatRetryOperation failureOperation,
    CharacterCard? imageCharacter,
  }) async {
    final llm = ref.read(llmProvider);
    final requestMessages = List<LlmRequestMessage>.of(history);
    // Pre-fetch/pre-search citations must stay in the same numbering space as
    // citations produced by later model tool calls.
    final citations = List<Citation>.of(initialCitations);
    final content = StringBuffer();
    final reasoning = StringBuffer();
    // Stopwatch for "已深度思考 N 秒": starts on first reasoning delta, freezes
    // once real answer content begins streaming.
    final thinkClock = Stopwatch();
    var thinkMillis = 0;
    var succeeded = false;

    Timer? uiFlushTimer;
    var uiDirty = false;
    var lastCheckpointAt = DateTime.now();
    var lastCheckpointLength = 0;

    void flushUi() {
      uiFlushTimer?.cancel();
      uiFlushTimer = null;
      if (!uiDirty) return;
      uiDirty = false;
      _updateAssistant(
        convoId,
        assistantId,
        content.toString(),
        reasoning.toString(),
        thinkMillis,
      );

      final totalLength = content.length + reasoning.length;
      final now = DateTime.now();
      if (totalLength > 0 &&
          (now.difference(lastCheckpointAt) >= _checkpointInterval ||
              totalLength - lastCheckpointLength >= _checkpointChars)) {
        lastCheckpointAt = now;
        lastCheckpointLength = totalLength;
        // Checkpoints are best-effort; the final awaited write below remains
        // the authoritative persistence error surface.
        _checkpointSoon(convoId);
      }
    }

    void scheduleUiFlush() {
      uiDirty = true;
      uiFlushTimer ??= Timer(_streamUiFlushInterval, flushUi);
    }

    late final void Function() flushActiveStream;
    flushActiveStream = flushUi;
    _flushActiveStream = flushActiveStream;

    // N search rounds (user-configurable) plus one final round with tools
    // withheld so the model must produce an answer.
    final maxToolRounds = settings.searchMaxRounds + 1;
    try {
      for (var round = 0; round < maxToolRounds; round++) {
        final toolDrafts = <int, ToolCallDraft>{};
        final turnContent = StringBuffer();
        final turnReasoning = StringBuffer();
        String? finishReason;
        Object? streamError;

        // On the LAST round drop the tool list entirely so the model is forced
        // to answer from what it has, instead of us erroring out mid-answer.
        final allowTools =
            enableTools && toolSpecs.isNotEmpty && round < maxToolRounds - 1;
        final stream = llm.streamChat(
          config: config,
          messages: requestMessages,
          tools: allowTools ? toolSpecs : null,
          thinking: thinking,
          cancelToken: cancelToken,
        );
        final completer = Completer<void>();
        _streamCompleter = completer;

        _sub = stream.listen(
          (chunk) {
            finishReason = chunk.finishReason ?? finishReason;
            if (chunk.reasoningDelta != null &&
                chunk.reasoningDelta!.isNotEmpty) {
              if (!thinkClock.isRunning && thinkMillis == 0) {
                thinkClock.start();
              }
              turnReasoning.write(chunk.reasoningDelta!);
              reasoning.write(chunk.reasoningDelta!);
            }
            if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
              if (thinkClock.isRunning) {
                thinkClock.stop();
                thinkMillis = thinkClock.elapsedMilliseconds;
              }
              turnContent.write(chunk.contentDelta!);
              content.write(chunk.contentDelta!);
            }
            for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
              (toolDrafts[call.index] ??= ToolCallDraft(
                call.index,
              )).merge(call);
            }
            scheduleUiFlush();
          },
          onError: (Object e) {
            streamError = e;
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

        await completer.future;
        if (identical(_streamCompleter, completer)) _streamCompleter = null;
        _sub = null;

        // The fake/test stream and very short real answers may finish before
        // the coalescing timer fires, so always publish pending content here.
        flushUi();

        if (streamError != null) throw streamError!;
        if (!_s.isStreaming) {
          await _persistById(convoId);
          return false;
        }

        if (thinkClock.isRunning) {
          thinkClock.stop();
          thinkMillis = thinkClock.elapsedMilliseconds;
          uiDirty = true;
          flushUi();
        }

        final toolCalls = ToolCallDraft.finalize(toolDrafts);
        final needsTools =
            allowTools &&
            (toolCalls.isNotEmpty || finishReason == 'tool_calls');
        if (!needsTools) {
          _set(
            _s.copyWith(
              streamingConvoId: null,
              isSearching: false,
              isGeneratingImage: false,
            ),
          );
          await _persistById(convoId);
          succeeded = true;
          return true;
        }

        if (toolCalls.isEmpty) {
          throw Exception('模型请求了工具调用，但没有返回可执行的工具参数。');
        }

        requestMessages.add(
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: turnContent.toString(),
            reasoningContent: turnReasoning.toString(),
            toolCalls: toolCalls,
          ),
        );

        // Clear transient "let me search" text from the visible answer. The
        // final response will stream in after tool results are appended.
        content.clear();
        uiDirty = true;
        flushUi();

        final toolMessages = await _executeToolCalls(
          toolCalls: toolCalls,
          settings: settings,
          fallbackSearchQuery: fallbackSearchQuery,
          convoId: convoId,
          assistantId: assistantId,
          citations: citations,
          allowedFetchUrls: allowedFetchUrls,
          cancelToken: cancelToken,
          imageBudget: imageBudget,
          imageCharacter: imageCharacter,
        );
        if (!_s.isStreaming) {
          await _persistById(convoId);
          return false;
        }
        requestMessages.addAll(toolMessages);

        // Tool responses can be much larger than the original conversation.
        // Re-budget before the next model round while keeping each assistant
        // tool-call and its tool results as an indivisible protocol unit.
        final roundContext = ref
            .read(contextWindowManagerProvider)
            .manage(requestMessages, settings.context);
        requestMessages
          ..clear()
          ..addAll(roundContext.messages);
        _recordContextReport(convoId, roundContext.report, accumulate: true);
        if (settings.context.enabled &&
            roundContext.report.sentTokens >
                roundContext.report.inputBudgetTokens) {
          throw Exception('工具结果超过上下文预算，请减少附件、关闭联网搜索，或在设置中增大上下文窗口。');
        }
      }
    } catch (e) {
      flushUi();
      if (thinkClock.isRunning) thinkClock.stop();
      _set(
        _s.copyWith(
          streamingConvoId: null,
          isSearching: false,
          isGeneratingImage: false,
          // A cancellation raised by stop() is not an error to surface.
          error: _isCancel(e) ? null : _describeError(e),
          errorConvoId: _isCancel(e) ? null : convoId,
          retryOperation: _isCancel(e) ? null : failureOperation,
        ),
      );
      await _persistById(convoId);
      return false;
    } finally {
      uiFlushTimer?.cancel();
      if (identical(_flushActiveStream, flushActiveStream)) {
        _flushActiveStream = null;
      }
      // Drop our token once finished so a later stop() can't cancel a stale one.
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
    return succeeded;
  }

  Future<List<LlmRequestMessage>> _executeToolCalls({
    required List<ToolCall> toolCalls,
    required SettingsState settings,
    required String fallbackSearchQuery,
    required String convoId,
    required String assistantId,
    required List<Citation> citations,
    required Set<String> allowedFetchUrls,
    required CancelToken cancelToken,
    required _TurnImageBudget imageBudget,
    CharacterCard? imageCharacter,
  }) async {
    final out = <LlmRequestMessage>[];
    try {
      for (var callIndex = 0; callIndex < toolCalls.length; callIndex++) {
        final call = toolCalls[callIndex];
        final toolCallId = call.id ?? '';
        // Per-tool composer hints — never reuse "正在联网搜索" for image gen.
        if (_s.isStreaming) {
          final searching =
              call.name == ToolEngine.webSearchTool.name ||
              call.name == ToolEngine.fetchUrlTool.name;
          final generating = call.name == ToolEngine.generateImageTool.name;
          _set(
            _s.copyWith(isSearching: searching, isGeneratingImage: generating),
          );
        }
        String toolContent;
        if (callIndex >= _maxToolCallsPerRound) {
          // Every requested call still gets a protocol-valid tool response, but
          // an untrusted/misbehaving model cannot fan out an unbounded number
          // of network requests in one turn.
          toolContent = '本轮最多执行 $_maxToolCallsPerRound 次工具调用；其余请求已跳过。';
        } else if (call.name == ToolEngine.webSearchTool.name) {
          toolContent = await _runWebSearchTool(
            call,
            settings,
            fallbackSearchQuery,
            convoId,
            assistantId,
            citations,
            cancelToken,
          );
        } else if (call.name == ToolEngine.fetchUrlTool.name) {
          toolContent = await _runFetchUrlTool(
            call,
            settings,
            convoId,
            assistantId,
            citations,
            allowedFetchUrls,
            cancelToken,
          );
        } else if (call.name == ToolEngine.generateImageTool.name) {
          toolContent = await _runGenerateImageTool(
            call,
            settings: settings,
            convoId: convoId,
            assistantId: assistantId,
            imageBudget: imageBudget,
            imageCharacter: imageCharacter,
            userText: fallbackSearchQuery,
            cancelToken: cancelToken,
          );
        } else {
          toolContent = '不支持的工具：${call.name ?? 'unknown'}';
        }
        out.add(
          LlmRequestMessage(
            role: MessageRole.tool,
            content: toolContent,
            toolCallId: toolCallId,
          ),
        );
      }
    } finally {
      _set(_s.copyWith(isSearching: false, isGeneratingImage: false));
    }
    return out;
  }

  Future<String> _runWebSearchTool(
    ToolCall call,
    SettingsState settings,
    String fallbackSearchQuery,
    String convoId,
    String assistantId,
    List<Citation> citations,
    CancelToken cancelToken,
  ) async {
    final query = _searchQueryFromArgs(call.argumentsJson, fallbackSearchQuery);
    try {
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: settings.searchBackend,
        apiKey: settings.searchApiKey,
      );
      final context = await engine.runSearch(
        query,
        maxResults: settings.searchMaxResults,
        startIndex: citations.length + 1,
        // Sources already cited this answer are skipped so repeated/nearby
        // queries surface new pages instead of duplicates.
        excludeUrls: {for (final c in citations) c.url},
        onActivity: (a) => _upsertSearchActivity(convoId, assistantId, a),
        cancelToken: cancelToken,
      );
      if (context.citations.isNotEmpty) {
        citations.addAll(context.citations);
        _setCitations(convoId, assistantId, List<Citation>.of(citations));
      }
      return context.contextText.isEmpty
          ? '没有搜索到与 "$query" 相关的结果。'
          : context.contextText;
    } catch (e) {
      // Stop pressed mid-search: the caller's !isStreaming check bails out.
      if (_isCancel(e)) return '搜索已取消。';
      _setScopedError(_describeError(e), convoId: convoId);
      return '联网搜索失败：$e';
    }
  }

  Future<String> _runFetchUrlTool(
    ToolCall call,
    SettingsState settings,
    String convoId,
    String assistantId,
    List<Citation> citations,
    Set<String> allowedFetchUrls,
    CancelToken cancelToken,
  ) async {
    final url = _urlFromArgs(call.argumentsJson);
    if (url == null) {
      return '无效的 URL 参数；请提供完整的 http(s) 网址。';
    }
    if (!allowedFetchUrls.contains(_fetchUrlKey(url))) {
      return '已拒绝读取：fetch_url 只能访问用户在本轮消息中明确提供的网址。';
    }
    try {
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: settings.searchBackend,
        apiKey: settings.searchApiKey,
      );
      final context = await engine.runFetchUrls(
        [url],
        startIndex: citations.length + 1,
        onActivity: (a) => _upsertSearchActivity(convoId, assistantId, a),
        cancelToken: cancelToken,
      );
      if (context.citations.isNotEmpty) {
        citations.addAll(context.citations);
        _setCitations(convoId, assistantId, List<Citation>.of(citations));
      }
      return context.contextText.isEmpty ? '未能读取网页：$url' : context.contextText;
    } catch (e) {
      if (_isCancel(e)) return '网页读取已取消。';
      _setScopedError(_describeError(e), convoId: convoId);
      return '读取网页失败：$e';
    }
  }

  Future<String> _runGenerateImageTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required _TurnImageBudget imageBudget,
    required CharacterCard? imageCharacter,
    required String userText,
    required CancelToken cancelToken,
  }) async {
    if (!imageBudget.canGenerate) {
      return '本轮已生成过图片，每轮对话最多一张。';
    }
    if (!settings.imageGenerationConfigured) {
      return '未配置图片生成 API，无法配图。';
    }
    final args = _imageToolArgs(call.argumentsJson);
    final result = await _runDialogueImageGeneration(
      settings: settings,
      convoId: convoId,
      assistantId: assistantId,
      character: imageCharacter,
      userText: userText,
      modelPrompt: args.prompt,
      briefHint: args.briefHint,
      cancelToken: cancelToken,
      // Tool path: model already wrote a prompt; skip a second LLM round.
      optimizeWithDeepThink: false,
    );
    if (result.ok) {
      imageBudget.markUsed();
      return imageCharacter != null
          ? '已为角色「${imageCharacter.name}」生成安全立绘，并附在本轮回复中。请用文字承接，勿再索取生图。'
          : '配图已生成并附在本轮回复中。请用文字承接，勿再索取生图。';
    }
    if (cancelToken.isCancelled || !_s.isStreaming) {
      return '生图已取消。';
    }
    return '生图失败：${result.error ?? '未知错误'}';
  }

  /// Which character card (if any) should own dialogue portrait generation.
  Future<CharacterCard?> _resolveImageCharacter(
    Conversation convo, {
    CharacterCard? ensembleSpeaker,
  }) async {
    if (ensembleSpeaker != null) return ensembleSpeaker;
    if (convo.isEnsemble) return null;
    // Director multi-cast: no single "the character" — skip card portraits
    // unless a dedicated speaker is provided above.
    if (convo.isStory && convo.localCast.isNotEmpty) return null;
    final id = convo.characterId;
    if (id == null || id.isEmpty) return null;
    return ref.read(characterRepositoryProvider).getById(id);
  }

  /// Shared path for force pre-gen and `generate_image` tool execution.
  Future<({bool ok, String? error})> _runDialogueImageGeneration({
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required CharacterCard? character,
    required String userText,
    required String? modelPrompt,
    required String? briefHint,
    required CancelToken cancelToken,
    required bool optimizeWithDeepThink,
  }) async {
    if (!settings.imageGenerationConfigured) {
      return (ok: false, error: '请先在设置中完整配置图片生成 API。');
    }
    if (cancelToken.isCancelled || !_s.isStreaming) {
      return (ok: false, error: null);
    }

    String prompt;
    if (character != null) {
      // Character book: portrait from card only. Never inject R18 user prose.
      prompt = ImagePromptSafety.characterPortrait(
        character,
        userHint: briefHint,
      );
    } else {
      final draft = (modelPrompt != null && modelPrompt.trim().isNotEmpty)
          ? modelPrompt
          : userText;
      prompt = ImagePromptSafety.freeform(draft);
      if (optimizeWithDeepThink && settings.config.isReady) {
        try {
          final refined = await _optimizeImagePrompt(
            userPrompt: prompt,
            settings: settings,
            cancelToken: cancelToken,
            onReasoning: (_, _) {},
          );
          if (refined.isNotEmpty) {
            prompt = ImagePromptSafety.freeform(refined);
          }
        } catch (e) {
          if (_isCancel(e) || cancelToken.isCancelled) {
            return (ok: false, error: null);
          }
          // Fall through with the scrubbed draft.
        }
      }
    }
    if (prompt.trim().isEmpty) {
      return (ok: false, error: '生图提示词为空。');
    }

    if (_s.isStreaming) {
      _set(_s.copyWith(isGeneratingImage: true, isSearching: false));
    }
    try {
      final generated = await ref
          .read(mediaApiProvider)
          .generateImage(
            config: settings.imageGenerationApi,
            apiKey: settings.imageGenerationApiKey,
            prompt: prompt,
            cancelToken: cancelToken,
          );
      if (cancelToken.isCancelled || !_s.isStreaming) {
        return (ok: false, error: null);
      }
      final sizeBytes = generated.base64 == null
          ? 0
          : (generated.base64!.length * 3 / 4).round();
      final attachment = Attachment(
        name: 'dialogue-${DateTime.now().millisecondsSinceEpoch}.png',
        mimeType: generated.mimeType,
        sizeBytes: sizeBytes,
        imageBase64: generated.base64,
        remoteUrl: generated.remoteUrl,
      );
      _appendAssistantAttachment(convoId, assistantId, attachment);
      return (ok: true, error: null);
    } catch (e) {
      if (_isCancel(e) || cancelToken.isCancelled) {
        return (ok: false, error: null);
      }
      return (ok: false, error: _describeError(e));
    } finally {
      if (_s.isGeneratingImage) {
        _set(_s.copyWith(isGeneratingImage: false));
      }
    }
  }

  void _appendAssistantAttachment(
    String convoId,
    String msgId,
    Attachment attachment,
  ) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return;
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId)
          m.copyWith(attachments: [...m.attachments, attachment])
        else
          m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  ({String? prompt, String? briefHint}) _imageToolArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final prompt = decoded['prompt'] is String
            ? (decoded['prompt'] as String).trim()
            : null;
        final hint = decoded['brief_hint'] is String
            ? (decoded['brief_hint'] as String).trim()
            : (decoded['briefHint'] is String
                  ? (decoded['briefHint'] as String).trim()
                  : null);
        return (
          prompt: prompt?.isEmpty ?? true ? null : prompt,
          briefHint: hint?.isEmpty ?? true ? null : hint,
        );
      }
    } catch (_) {
      // Malformed JSON from the model.
    }
    return (prompt: null, briefHint: null);
  }

  String _searchQueryFromArgs(String raw, String fallback) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['query'] is String) {
        final query = normalizeSearchQuery(decoded['query'] as String);
        if (query.isNotEmpty) return query;
      }
    } catch (_) {
      // Fall through to the user turn if the model returned malformed JSON.
    }
    return normalizeSearchQuery(fallback);
  }

  /// Parse a single URL from a tool-call arguments JSON blob.
  String? _urlFromArgs(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['url'] is String) {
        final url = (decoded['url'] as String).trim();
        if (url.isNotEmpty && HttpSearchProvider.isSafeHttpUrl(url)) {
          return url;
        }
      }
    } catch (_) {
      // Malformed JSON from the model.
    }
    return null;
  }

  /// Canonical comparison key for the per-turn fetch allow-list.
  String _fetchUrlKey(String url) {
    final uri = Uri.parse(url);
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: uri.path.isEmpty ? '/' : uri.path,
          fragment: '',
        )
        .normalizePath()
        .toString();
  }

  /// Tool-capable config for the "搜索大脑" planner, or null when the chosen
  /// model cannot do function calling (the caller then falls back to a plain
  /// single-shot search).
  LlmConfig? _searchBrainConfig(SettingsState settings) {
    final config = LlmConfig(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.effectiveSearchBrainModel,
    );
    if (!config.isReady || !config.capabilities.supportsTools) return null;
    return config;
  }

  /// Multi-round planner retrieval with graceful degradation to the classic
  /// one-shot search when no tool-capable brain model is available.
  Future<SearchOrchestration> _runOrchestratedSearch({
    required ToolEngine engine,
    required SettingsState settings,
    required Conversation working,
    required String assistantId,
    required String searchQuery,
    required bool force,
    required int startIndex,
    required SearchActivityListener onActivity,
    required CancelToken cancelToken,
  }) async {
    final brain = _searchBrainConfig(settings);
    if (brain == null) {
      final searched = await engine.runSearch(
        normalizeSearchQuery(searchQuery),
        maxResults: settings.searchMaxResults,
        startIndex: startIndex,
        onActivity: onActivity,
        cancelToken: cancelToken,
      );
      return SearchOrchestration(context: searched, searched: true);
    }

    // Planner context: the visible branch minus the assistant placeholder and
    // minus the current question (passed separately as userQuery).
    final path = working.activePath.where((m) => m.id != assistantId).toList();
    if (path.isNotEmpty &&
        path.last.role == MessageRole.user &&
        path.last.content == searchQuery) {
      path.removeLast();
    }
    final history = [
      for (final m in path) LlmRequestMessage(role: m.role, content: m.content),
    ];

    final orchestrator = SearchOrchestrator(ref.read(llmProvider), engine);
    return orchestrator.run(
      brainConfig: brain,
      history: history,
      userQuery: searchQuery,
      force: force,
      maxRounds: settings.searchMaxRounds,
      maxResults: settings.searchMaxResults,
      startIndex: startIndex,
      onActivity: onActivity,
      cancelToken: cancelToken,
    );
  }

  /// Adds or replaces (by id) one search-process step on the assistant bubble.
  void _upsertSearchActivity(
    String convoId,
    String msgId,
    SearchActivity activity,
  ) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return; // conversation was deleted mid-stream
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId)
          m.copyWith(
            searchActivities: _mergeActivity(m.searchActivities, activity),
          )
        else
          m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  static List<SearchActivity> _mergeActivity(
    List<SearchActivity> current,
    SearchActivity update,
  ) {
    final out = List<SearchActivity>.of(current);
    final i = out.indexWhere((a) => a.id == update.id);
    if (i >= 0) {
      out[i] = update;
    } else {
      out.add(update);
    }
    return List.unmodifiable(out);
  }

  void _setCitations(String convoId, String msgId, List<Citation> citations) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return; // conversation was deleted mid-stream
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId) m.copyWith(citations: citations) else m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  void _setAppliedWorldInfo(
    String convoId,
    String msgId,
    List<WorldInfoHit> hits,
  ) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return;
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId) m.copyWith(appliedWorldInfo: hits) else m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  /// Turn a stored [ChatMessage] into a request message: text attachments are
  /// inlined into the content; image attachments are sent as `image_url` parts
  /// when [vision] is true, otherwise described in text. Messages with no
  /// attachments pass through unchanged.
  LlmRequestMessage _toRequestMessage(ChatMessage m, {required bool vision}) {
    if (m.attachments.isEmpty || m.role != MessageRole.user) {
      return LlmRequestMessage.fromChatMessage(m);
    }

    final buffer = StringBuffer();
    final images = <String>[];
    for (final a in m.attachments) {
      if (a.isImage) {
        if (vision && a.hasImageData) {
          images.add(a.imageDataUrl); // sent through the image channel
        } else {
          buffer
            ..writeln('【图片：${a.name}】')
            ..writeln(a.parseError ?? '（当前模型不支持图片，未发送图片内容）')
            ..writeln();
        }
        continue;
      }
      buffer.writeln('【文件：${a.name}】');
      if (a.parseError != null) {
        buffer.writeln('（${a.parseError}）');
      } else {
        buffer.writeln(a.text);
        if (a.truncated) buffer.writeln('…（内容过长，已截断）');
      }
      buffer.writeln();
    }
    if (m.content.isNotEmpty) buffer.write(m.content);

    return LlmRequestMessage(
      role: m.role,
      content: buffer.toString(),
      imageDataUrls: images,
    );
  }

  void _updateAssistant(
    String convoId,
    String msgId,
    String content,
    String reasoning,
    int thinkingMillis,
  ) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return; // conversation was deleted mid-stream
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId)
          m.copyWith(
            content: content,
            reasoning: reasoning,
            thinkingMillis: thinkingMillis,
          )
        else
          m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  void _updateGeneratedImage(
    String convoId,
    String msgId, {
    required String content,
    required Attachment attachment,
    String? reasoning,
    int? thinkingMillis,
    String? model,
  }) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return;
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId)
          m.copyWith(
            content: content,
            attachments: [attachment],
            reasoning: reasoning,
            thinkingMillis: thinkingMillis,
            model: model,
          )
        else
          m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  void _recordContextReport(
    String convoId,
    ContextWindowReport report, {
    bool accumulate = false,
  }) {
    final previous = accumulate ? _s.contextReports[convoId] : null;
    final combined = previous == null
        ? report
        : ContextWindowReport(
            originalTokens: previous.originalTokens > report.originalTokens
                ? previous.originalTokens
                : report.originalTokens,
            sentTokens: report.sentTokens,
            inputBudgetTokens: report.inputBudgetTokens,
            droppedMessages: previous.droppedMessages + report.droppedMessages,
            truncated: previous.truncated || report.truncated,
          );
    _set(
      _s.copyWith(contextReports: {..._s.contextReports, convoId: combined}),
    );
  }
}

final chatControllerProvider = AsyncNotifierProvider<ChatController, ChatState>(
  ChatController.new,
);
