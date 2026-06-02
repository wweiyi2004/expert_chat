import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/models.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/tools/search_provider.dart';
import '../domain/tools/tool_engine.dart';
import 'settings_controller.dart';

class ChatState {
  const ChatState({
    this.conversations = const [],
    this.currentId,
    this.isStreaming = false,
    this.deepThink = false,
    this.searchEnabled = false,
    this.isSearching = false,
    this.error,
  });

  final List<Conversation> conversations;
  final String? currentId;
  final bool isStreaming;

  /// When true the next send is routed to the reasoner model regardless of the
  /// configured default model (the "深度思考" toggle in the composer).
  final bool deepThink;

  /// When true the next send runs a web search first (the "联网" toggle).
  final bool searchEnabled;

  /// True while the pre-answer web search is running (drives a status hint).
  final bool isSearching;
  final String? error;

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
    bool? isStreaming,
    bool? deepThink,
    bool? searchEnabled,
    bool? isSearching,
    Object? error = _sentinel,
  }) =>
      ChatState(
        conversations: conversations ?? this.conversations,
        currentId: currentId ?? this.currentId,
        isStreaming: isStreaming ?? this.isStreaming,
        deepThink: deepThink ?? this.deepThink,
        searchEnabled: searchEnabled ?? this.searchEnabled,
        isSearching: isSearching ?? this.isSearching,
        error: identical(error, _sentinel) ? this.error : error as String?,
      );

  static const _sentinel = Object();
}

class ChatController extends AsyncNotifier<ChatState> {
  StreamSubscription<dynamic>? _sub;

  @override
  Future<ChatState> build() async {
    ref.onDispose(() => _sub?.cancel());
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

  /// Persist only the active conversation (cheap; avoids rewriting the whole DB
  /// on every turn).
  Future<void> _persist() {
    final cur = _s.current;
    if (cur == null) return Future.value();
    return ref.read(conversationRepositoryProvider).saveConversation(cur);
  }

  void _set(ChatState next) => state = AsyncData(next);

  /// Replace the current conversation in the list with [updated].
  List<Conversation> _replace(Conversation updated) => [
        for (final c in _s.conversations) c.id == updated.id ? updated : c,
      ];

  void newConversation() {
    final fresh = Conversation();
    _set(_s.copyWith(
      conversations: [fresh, ..._s.conversations],
      currentId: fresh.id,
      error: null,
    ));
    _persist();
  }

  void selectConversation(String id) {
    _set(_s.copyWith(currentId: id, error: null));
  }

  /// Toggle the "深度思考" switch shown next to the composer.
  void toggleDeepThink() {
    _set(_s.copyWith(deepThink: !_s.deepThink));
  }

  /// Toggle the "联网" (web search) switch shown next to the composer.
  void toggleSearch() {
    _set(_s.copyWith(searchEnabled: !_s.searchEnabled));
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
      ref.read(conversationRepositoryProvider).saveConversation(r);
    }
  }

  void deleteConversation(String id) {
    final repo = ref.read(conversationRepositoryProvider);
    repo.deleteConversation(id);
    final remaining = _s.conversations.where((c) => c.id != id).toList();
    if (remaining.isEmpty) {
      final fresh = Conversation();
      _set(_s.copyWith(conversations: [fresh], currentId: fresh.id));
      repo.saveConversation(fresh);
    } else {
      final newCurrent =
          _s.currentId == id ? remaining.first.id : _s.currentId;
      _set(_s.copyWith(conversations: remaining, currentId: newCurrent));
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _set(_s.copyWith(isStreaming: false));
    _persist();
  }

  /// Send a new user turn at the end of the active branch.
  Future<void> sendMessage(
    String text, {
    List<Attachment> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && attachments.isEmpty) || _s.isStreaming) return;

    final settings = await _readySettings();
    if (settings == null) return;
    final config = _configFor(settings);

    final convo = _s.current ?? Conversation();
    final parentId =
        convo.activePath.isEmpty ? null : convo.activePath.last.id;
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
      title: isFirst
          ? (titleSeed.length > 20 ? '${titleSeed.substring(0, 20)}…' : titleSeed)
          : convo.title,
      messages: [...convo.messages, userMsg, assistantMsg],
      activeChildren: {
        ...convo.activeChildren,
        parentId ?? kRootKey: userMsg.id,
        userMsg.id: assistantMsg.id,
      },
    );

    await _generate(
      working: working,
      assistantId: assistantMsg.id,
      config: config,
      settings: settings,
      searchQuery: trimmed,
      thinking: _s.deepThink,
    );
  }

  /// Edit a previous user message: creates a sibling under the same parent
  /// (keeping the old version as a branch) and regenerates from there.
  Future<void> editMessage(
    String messageId,
    String newText, {
    List<Attachment>? attachments,
  }) async {
    if (_s.isStreaming) return;
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;
    final convo = _s.current;
    if (convo == null) return;
    final old = convo.messages.firstWhere((m) => m.id == messageId,
        orElse: () => convo.messages.first);
    if (old.role != MessageRole.user) return;

    final settings = await _readySettings();
    if (settings == null) return;
    final config = _configFor(settings);

    final userMsg = ChatMessage(
      role: MessageRole.user,
      content: trimmed,
      attachments: attachments ?? old.attachments,
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

    await _generate(
      working: working,
      assistantId: assistantMsg.id,
      config: config,
      settings: settings,
      searchQuery: trimmed,
      thinking: _s.deepThink,
    );
  }

  /// Regenerate the last assistant reply as a NEW branch (the previous reply is
  /// kept and can be switched back to).
  Future<void> regenerate() async {
    if (_s.isStreaming) return;
    final convo = _s.current;
    if (convo == null) return;
    final path = convo.activePath;
    final lastUser = path.lastIndexWhere((m) => m.role == MessageRole.user);
    if (lastUser < 0) return;
    final userMsg = path[lastUser];

    final settings = await _readySettings();
    if (settings == null) return;
    final config = _configFor(settings);

    final assistantMsg = ChatMessage(
      role: MessageRole.assistant,
      content: '',
      model: config.model,
      parentId: userMsg.id,
    );
    final working = convo.copyWith(
      messages: [...convo.messages, assistantMsg],
      activeChildren: {...convo.activeChildren, userMsg.id: assistantMsg.id},
    );

    await _generate(
      working: working,
      assistantId: assistantMsg.id,
      config: config,
      settings: settings,
      searchQuery: userMsg.content,
      thinking: _s.deepThink,
    );
  }

  /// Switch which sibling branch is active at [messageId] (delta -1 / +1).
  void switchBranch(String messageId, int delta) {
    if (_s.isStreaming) return;
    final convo = _s.current;
    if (convo == null) return;
    final m = convo.messages.firstWhere((x) => x.id == messageId,
        orElse: () => convo.messages.first);
    final key = m.parentId ?? kRootKey;
    final sibs = convo.childrenOf(key);
    if (sibs.length < 2) return;
    final curIdx = sibs.indexWhere((x) => x.id == messageId);
    final newIdx = (curIdx + delta).clamp(0, sibs.length - 1);
    if (newIdx == curIdx) return;
    _set(_s.copyWith(
      conversations: _replace(convo.copyWith(
        activeChildren: {...convo.activeChildren, key: sibs[newIdx].id},
      )),
    ));
    _persist();
  }

  /// Resend the last user turn after a failure (the error banner's "重试").
  Future<void> retryLast() => regenerate();

  /// Validate settings; returns null (and sets an error) when not ready.
  Future<SettingsState?> _readySettings() async {
    final settings = await ref.read(settingsControllerProvider.future);
    if (!settings.config.isReady) {
      _set(_s.copyWith(error: '请先在设置中填写 API Key。'));
      return null;
    }
    return settings;
  }

  /// The deep-think toggle routes to the active profile's reasoner model.
  LlmConfig _configFor(SettingsState settings) => _s.deepThink
      ? settings.config.copyWith(model: settings.reasonerModel)
      : settings.config;

  /// Shared pipeline: show the pending turn, run optional web search, then
  /// stream the answer along the active branch.
  Future<void> _generate({
    required Conversation working,
    required String assistantId,
    required LlmConfig config,
    required SettingsState settings,
    required String searchQuery,
    required bool thinking,
  }) async {
    _set(_s.copyWith(
      conversations: _replace(working),
      currentId: working.id,
      isStreaming: true,
      isSearching: _s.searchEnabled,
      error: null,
    ));

    // Optional web-search pre-step (works for reasoner too, which can't do
    // function calling). On failure we surface a hint and answer without it.
    SearchContext? searchContext;
    if (_s.searchEnabled && searchQuery.trim().isNotEmpty) {
      try {
        final engine = ToolEngine(HttpSearchProvider(
          backend: settings.searchBackend,
          apiKey: settings.searchApiKey,
        ));
        searchContext = await engine.runSearch(searchQuery.trim());
        if (searchContext.citations.isNotEmpty) {
          _setCitations(working.id, assistantId, searchContext.citations);
        }
      } catch (e) {
        _set(_s.copyWith(error: e.toString()));
      }
    }
    _set(_s.copyWith(isSearching: false));

    // The user may have pressed stop during the (awaited) search; honor it.
    if (!_s.isStreaming) {
      _persist();
      return;
    }

    // Build the request from the CURRENT active branch (re-read state, since
    // citations may have replaced the conversation object), excluding the empty
    // assistant placeholder and expanding attachments into text.
    final cur = _s.conversations.firstWhere((c) => c.id == working.id,
        orElse: () => working);
    final history = cur.activePath
        .where((m) => m.id != assistantId)
        .map(_expandAttachments)
        .toList();

    if (searchContext != null && searchContext.contextText.isNotEmpty) {
      final insertAt = history.isEmpty ? 0 : history.length - 1;
      history.insert(
        insertAt,
        ChatMessage(
            role: MessageRole.system, content: searchContext.contextText),
      );
    }

    // Prepend the global preset/persona prompt as the very first system message
    // (before history and any search context) when configured.
    final preset = settings.systemPrompt.trim();
    if (preset.isNotEmpty) {
      history.insert(
        0,
        ChatMessage(role: MessageRole.system, content: preset),
      );
    }

    await _streamAnswer(
      config: config,
      history: history,
      convoId: working.id,
      assistantId: assistantId,
      thinking: thinking,
    );
  }

  Future<void> _streamAnswer({
    required LlmConfig config,
    required List<ChatMessage> history,
    required String convoId,
    required String assistantId,
    required bool thinking,
  }) async {
    final llm = ref.read(llmProvider);
    var content = '';
    var reasoning = '';
    // Stopwatch for "已深度思考 N 秒": starts on first reasoning delta, freezes
    // once real answer content begins streaming.
    final thinkClock = Stopwatch();
    var thinkMillis = 0;

    final stream =
        llm.streamChat(config: config, messages: history, thinking: thinking);
    final completer = Completer<void>();

    _sub = stream.listen(
      (chunk) {
        if (chunk.reasoningDelta != null && chunk.reasoningDelta!.isNotEmpty) {
          if (!thinkClock.isRunning && thinkMillis == 0) thinkClock.start();
          reasoning += chunk.reasoningDelta!;
        }
        if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
          if (thinkClock.isRunning) {
            thinkClock.stop();
            thinkMillis = thinkClock.elapsedMilliseconds;
          }
          content += chunk.contentDelta!;
        }
        _updateAssistant(convoId, assistantId, content, reasoning, thinkMillis);
      },
      onError: (Object e) {
        if (thinkClock.isRunning) thinkClock.stop();
        _set(_s.copyWith(isStreaming: false, error: e.toString()));
        _persist();
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (thinkClock.isRunning) {
          thinkClock.stop();
          thinkMillis = thinkClock.elapsedMilliseconds;
          _updateAssistant(convoId, assistantId, content, reasoning, thinkMillis);
        }
        _set(_s.copyWith(isStreaming: false));
        _persist();
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    await completer.future;
  }

  void _setCitations(String convoId, String msgId, List<Citation> citations) {
    final convo = _s.conversations.firstWhere(
      (c) => c.id == convoId,
      orElse: () => _s.conversations.first,
    );
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId) m.copyWith(citations: citations) else m,
    ];
    _set(_s.copyWith(
        conversations: _replace(convo.copyWith(messages: messages))));
  }

  /// Inline a message's attachment text so the model can read it. Returns the
  /// message unchanged when it has no attachments.
  ChatMessage _expandAttachments(ChatMessage m) {
    if (m.attachments.isEmpty) return m;
    final buffer = StringBuffer();
    for (final a in m.attachments) {
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
    return m.copyWith(content: buffer.toString());
  }

  void _updateAssistant(
    String convoId,
    String msgId,
    String content,
    String reasoning,
    int thinkingMillis,
  ) {
    final convo = _s.conversations.firstWhere(
      (c) => c.id == convoId,
      orElse: () => _s.conversations.first,
    );
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
    _set(_s.copyWith(conversations: _replace(convo.copyWith(messages: messages))));
  }
}

final chatControllerProvider =
    AsyncNotifierProvider<ChatController, ChatState>(ChatController.new);
