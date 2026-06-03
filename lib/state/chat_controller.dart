import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/models.dart';
import '../domain/llm/llm_provider.dart';
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

  /// When true the model may call the `web_search` tool while answering.
  final bool searchEnabled;

  /// True while a web-search tool call is running (drives a status hint).
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
  }) => ChatState(
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
  static const int _maxToolRounds = 3;

  StreamSubscription<dynamic>? _sub;
  Completer<void>? _streamCompleter;

  /// Cancels the active LLM HTTP request (set per generation, fired by [stop]).
  CancelToken? _cancelToken;

  @override
  Future<ChatState> build() async {
    ref.onDispose(() {
      _sub?.cancel();
      _cancelToken?.cancel();
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
    _set(
      _s.copyWith(
        conversations: [fresh, ..._s.conversations],
        currentId: fresh.id,
        error: null,
      ),
    );
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
      final newCurrent = _s.currentId == id ? remaining.first.id : _s.currentId;
      _set(_s.copyWith(conversations: remaining, currentId: newCurrent));
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    // Abort the underlying HTTP request too, so it stops consuming tokens.
    _cancelToken?.cancel();
    _cancelToken = null;
    final completer = _streamCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _set(_s.copyWith(isStreaming: false, isSearching: false));
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
    final parentId = convo.activePath.isEmpty ? null : convo.activePath.last.id;
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
          ? (titleSeed.length > 20
                ? '${titleSeed.substring(0, 20)}…'
                : titleSeed)
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
    final old = convo.messages.firstWhere(
      (m) => m.id == messageId,
      orElse: () => convo.messages.first,
    );
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
    final m = convo.messages.firstWhere(
      (x) => x.id == messageId,
      orElse: () => convo.messages.first,
    );
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

  /// Shared pipeline: show the pending turn, optionally expose `web_search` as
  /// a model-controlled tool, then stream the answer along the active branch.
  Future<void> _generate({
    required Conversation working,
    required String assistantId,
    required LlmConfig config,
    required SettingsState settings,
    required String searchQuery,
    required bool thinking,
  }) async {
    final searchAllowed = _s.searchEnabled && searchQuery.trim().isNotEmpty;
    final useWebSearchTool = searchAllowed && config.capabilities.supportsTools;

    _set(
      _s.copyWith(
        conversations: _replace(working),
        currentId: working.id,
        isStreaming: true,
        isSearching: false,
        error: null,
      ),
    );

    // Fallback for legacy models that reject tool-call parameters: keep the old
    // explicit search-first behavior so the feature still works.
    SearchContext? searchContext;
    if (searchAllowed && !useWebSearchTool) {
      _set(_s.copyWith(isSearching: true));
      try {
        final engine = ref.read(toolEngineFactoryProvider)(
          backend: settings.searchBackend,
          apiKey: settings.searchApiKey,
        );
        searchContext = await engine.runSearch(searchQuery.trim());
        if (searchContext.citations.isNotEmpty) {
          _setCitations(working.id, assistantId, searchContext.citations);
        }
      } catch (e) {
        _set(_s.copyWith(error: e.toString()));
      } finally {
        _set(_s.copyWith(isSearching: false));
      }
    }

    // The user may have pressed stop during the (awaited) search; honor it.
    if (!_s.isStreaming) {
      _persist();
      return;
    }

    // Build the request from the CURRENT active branch (re-read state, since
    // citations may have replaced the conversation object), excluding the empty
    // assistant placeholder and expanding attachments into text.
    final cur = _s.conversations.firstWhere(
      (c) => c.id == working.id,
      orElse: () => working,
    );
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

    // Prepend the global preset/persona prompt as the very first system message
    // (before history and any search context) when configured.
    final preset = settings.systemPrompt.trim();
    if (preset.isNotEmpty) {
      history.insert(
        0,
        LlmRequestMessage(role: MessageRole.system, content: preset),
      );
    }

    await _streamAnswer(
      config: config,
      history: history,
      convoId: working.id,
      assistantId: assistantId,
      thinking: thinking,
      settings: settings,
      fallbackSearchQuery: searchQuery,
      enableWebSearchTool: useWebSearchTool,
    );
  }

  Future<void> _streamAnswer({
    required LlmConfig config,
    required List<LlmRequestMessage> history,
    required String convoId,
    required String assistantId,
    required bool thinking,
    required SettingsState settings,
    required String fallbackSearchQuery,
    required bool enableWebSearchTool,
  }) async {
    final llm = ref.read(llmProvider);
    // One token covers all tool rounds of this generation; stop() fires it.
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    final requestMessages = List<LlmRequestMessage>.of(history);
    final citations = <Citation>[];
    var content = '';
    var reasoning = '';
    // Stopwatch for "已深度思考 N 秒": starts on first reasoning delta, freezes
    // once real answer content begins streaming.
    final thinkClock = Stopwatch();
    var thinkMillis = 0;

    try {
      for (var round = 0; round < _maxToolRounds; round++) {
        final toolDrafts = <int, _ToolCallDraft>{};
        var turnContent = '';
        var turnReasoning = '';
        String? finishReason;
        Object? streamError;

        final stream = llm.streamChat(
          config: config,
          messages: requestMessages,
          tools: enableWebSearchTool ? const [ToolEngine.webSearchTool] : null,
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
              turnReasoning += chunk.reasoningDelta!;
              reasoning += chunk.reasoningDelta!;
            }
            if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
              if (thinkClock.isRunning) {
                thinkClock.stop();
                thinkMillis = thinkClock.elapsedMilliseconds;
              }
              turnContent += chunk.contentDelta!;
              content += chunk.contentDelta!;
            }
            for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
              (toolDrafts[call.index] ??= _ToolCallDraft(
                call.index,
              )).merge(call);
            }
            _updateAssistant(
              convoId,
              assistantId,
              content,
              reasoning,
              thinkMillis,
            );
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

        if (streamError != null) throw streamError!;
        if (!_s.isStreaming) {
          _persist();
          return;
        }

        if (thinkClock.isRunning) {
          thinkClock.stop();
          thinkMillis = thinkClock.elapsedMilliseconds;
          _updateAssistant(
            convoId,
            assistantId,
            content,
            reasoning,
            thinkMillis,
          );
        }

        final toolCalls = _finalizeToolCalls(toolDrafts);
        final needsTools =
            enableWebSearchTool &&
            (toolCalls.isNotEmpty || finishReason == 'tool_calls');
        if (!needsTools) {
          _set(_s.copyWith(isStreaming: false, isSearching: false));
          await _persist();
          return;
        }

        if (toolCalls.isEmpty) {
          throw Exception('模型请求了工具调用，但没有返回可执行的工具参数。');
        }
        if (round == _maxToolRounds - 1) {
          throw Exception('联网搜索工具调用轮次过多，已停止。');
        }

        requestMessages.add(
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: turnContent,
            reasoningContent: turnReasoning,
            toolCalls: toolCalls,
          ),
        );

        // Clear transient "let me search" text from the visible answer. The
        // final response will stream in after tool results are appended.
        content = '';
        _updateAssistant(convoId, assistantId, content, reasoning, thinkMillis);

        final toolMessages = await _executeToolCalls(
          toolCalls: toolCalls,
          settings: settings,
          fallbackSearchQuery: fallbackSearchQuery,
          convoId: convoId,
          assistantId: assistantId,
          citations: citations,
        );
        if (!_s.isStreaming) {
          await _persist();
          return;
        }
        requestMessages.addAll(toolMessages);
      }
    } catch (e) {
      if (thinkClock.isRunning) thinkClock.stop();
      _set(
        _s.copyWith(
          isStreaming: false,
          isSearching: false,
          error: e.toString(),
        ),
      );
      await _persist();
    } finally {
      // Drop our token once finished so a later stop() can't cancel a stale one.
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
    }
  }

  List<ToolCall> _finalizeToolCalls(Map<int, _ToolCallDraft> drafts) {
    final calls = drafts.values.map((d) => d.build()).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return calls.where((c) => (c.name ?? '').isNotEmpty).toList();
  }

  Future<List<LlmRequestMessage>> _executeToolCalls({
    required List<ToolCall> toolCalls,
    required SettingsState settings,
    required String fallbackSearchQuery,
    required String convoId,
    required String assistantId,
    required List<Citation> citations,
  }) async {
    final out = <LlmRequestMessage>[];
    _set(_s.copyWith(isSearching: true));
    try {
      for (final call in toolCalls) {
        final toolCallId = call.id ?? '';
        String toolContent;
        if (call.name != ToolEngine.webSearchTool.name) {
          toolContent = '不支持的工具：${call.name ?? 'unknown'}';
        } else {
          toolContent = await _runWebSearchTool(
            call,
            settings,
            fallbackSearchQuery,
            convoId,
            assistantId,
            citations,
          );
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
      _set(_s.copyWith(isSearching: false));
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
  ) async {
    final query = _searchQueryFromArgs(call.argumentsJson, fallbackSearchQuery);
    try {
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: settings.searchBackend,
        apiKey: settings.searchApiKey,
      );
      final context = await engine.runSearch(
        query,
        startIndex: citations.length + 1,
      );
      if (context.citations.isNotEmpty) {
        citations.addAll(context.citations);
        _setCitations(convoId, assistantId, List<Citation>.of(citations));
      }
      return context.contextText.isEmpty
          ? '没有搜索到与 "$query" 相关的结果。'
          : context.contextText;
    } catch (e) {
      _set(_s.copyWith(error: e.toString()));
      return '联网搜索失败：$e';
    }
  }

  String _searchQueryFromArgs(String raw, String fallback) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['query'] is String) {
        final query = (decoded['query'] as String).trim();
        if (query.isNotEmpty) return query;
      }
    } catch (_) {
      // Fall through to the user turn if the model returned malformed JSON.
    }
    return fallback.trim();
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
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  /// Turn a stored [ChatMessage] into a request message: text attachments are
  /// inlined into the content; image attachments are sent as `image_url` parts
  /// when [vision] is true, otherwise described in text. Messages with no
  /// attachments pass through unchanged.
  LlmRequestMessage _toRequestMessage(ChatMessage m, {required bool vision}) {
    if (m.attachments.isEmpty) return LlmRequestMessage.fromChatMessage(m);

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
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }
}

final chatControllerProvider = AsyncNotifierProvider<ChatController, ChatState>(
  ChatController.new,
);

class _ToolCallDraft {
  _ToolCallDraft(this.index);

  final int index;
  String? id;
  String? name;
  final StringBuffer _arguments = StringBuffer();

  void merge(ToolCall call) {
    id ??= call.id;
    name ??= call.name;
    if (call.argumentsJson.isNotEmpty) _arguments.write(call.argumentsJson);
  }

  ToolCall build() => ToolCall(
    index: index,
    id: id ?? 'call_${index}_${DateTime.now().microsecondsSinceEpoch}',
    name: name,
    argumentsJson: _arguments.toString(),
  );
}
