part of '../chat_controller.dart';

mixin ChatMutations on _ChatControllerBase {
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

  Future<void> _importImageToLibrary(Attachment attachment) async {
    if (!attachment.hasDownloadableBytes) return;
    try {
      await ref
          .read(libraryRepositoryProvider)
          .importBytes(
            name: attachment.name,
            mimeType: attachment.mimeType,
            bytes: Uint8List.fromList(base64Decode(attachment.imageBase64!)),
          );
    } catch (_) {}
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
            searchActivities: _mergeActivity(
              m.searchActivities,
              _stampReasoningOffset(m, activity),
            ),
          )
        else
          m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  static SearchActivity _stampReasoningOffset(
    ChatMessage message,
    SearchActivity activity,
  ) {
    for (final existing in message.searchActivities) {
      if (existing.id == activity.id) {
        return activity.copyWith(reasoningOffset: existing.reasoningOffset);
      }
    }
    return activity.copyWith(reasoningOffset: message.reasoning.length);
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
  LlmRequestMessage _toRequestMessage(
    ChatMessage m, {
    required bool vision,
    bool imageToolAvailable = false,
  }) {
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
          buffer.writeln('【图片：${a.name}】');
          if (imageToolAvailable) {
            buffer.writeln(
              '（像素未发送给对话模型；需要看图时请调用 analyze_image，'
              'attachment_name 用此文件名）',
            );
          } else {
            buffer.writeln(a.parseError ?? '（当前模型不支持图片，未发送图片内容）');
          }
          buffer.writeln();
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
            summaryInjected: previous.summaryInjected || report.summaryInjected,
          );
    _set(
      _s.copyWith(contextReports: {..._s.contextReports, convoId: combined}),
    );
  }
}
