part of '../chat_controller.dart';

// Internal library mixin; the public controller composes these implementation parts.
// ignore: library_private_types_in_public_api
mixin ChatMutations on _ChatControllerBase {
  ChatMessage? _messageById(String convoId, String msgId) => _s.conversations
      .where((c) => c.id == convoId)
      .firstOrNull
      ?.messages
      .where((m) => m.id == msgId)
      .firstOrNull;

  void _endPendingActivities(String convoId, String msgId, String reason) {
    final message = _messageById(convoId, msgId);
    if (message == null) return;
    for (final activity in message.searchActivities) {
      if (activity.status == SearchActivityStatus.running) {
        _upsertSearchActivity(
          convoId,
          msgId,
          activity.copyWith(
            status: SearchActivityStatus.failed,
            error: reason,
            interrupted:
                _execution.isCancelled || (_run?.userCancelled ?? false),
          ),
        );
      }
    }
  }

  void _recordToolResult(
    String convoId,
    String msgId,
    ToolCall call,
    String result,
    Set<String> priorIds, {
    String? createdActivityId,
  }) {
    final message = _messageById(convoId, msgId);
    if (message == null) return;
    final legacyKind = switch (call.name) {
      'web_search' => SearchActivityKind.search,
      'fetch_url' => SearchActivityKind.fetch,
      'analyze_image' => SearchActivityKind.vision,
      _ => null,
    };
    final created = message.searchActivities
        .where(
          (a) =>
              !priorIds.contains(a.id) &&
              (createdActivityId != null
                  ? a.id == createdActivityId
                  : ((a.toolCallId != null && a.toolCallId == call.id) ||
                        (a.toolName == call.name &&
                            a.toolArguments == call.argumentsJson) ||
                        (legacyKind != null &&
                            a.toolName == null &&
                            a.kind == legacyKind))),
        )
        .toList();
    for (final activity in created) {
      _upsertSearchActivity(
        convoId,
        msgId,
        activity.copyWith(
          toolName: call.name,
          toolArguments:
              (activity.id == createdActivityId || activity.toolCallId != null)
              ? activity.toolArguments
              : call.argumentsJson,
        ),
      );
    }
    final activity = created.isEmpty
        ? SearchActivity(
            kind: SearchActivityKind.mcp,
            query: call.name ?? '未知工具',
            status: SearchActivityStatus.failed,
            error: '未执行或没有可恢复的步骤记录',
          )
        : created.last;
    _upsertSearchActivity(
      convoId,
      msgId,
      activity.copyWith(
        toolName: created.isEmpty ? null : call.name,
        toolArguments: created.isEmpty
            ? null
            : (activity.id == createdActivityId || activity.toolCallId != null)
            ? activity.toolArguments
            : call.argumentsJson,
        resultText: result.length > 64000
            ? '${result.substring(0, 64000)}\n【结果过长，已截断】'
            : result,
      ),
    );
    _persistence.checkpointSoon(convoId);
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

  Future<void> _recordImageVersion({
    required Attachment output,
    required SettingsState settings,
    required String originalPrompt,
    required String sentPrompt,
    String? revisedPrompt,
    required String convoId,
    required String messageId,
    String? parentGenerationId,
    List<ImageEditReference> references = const [],
  }) async {
    try {
      await ref
          .read(generationRepositoryProvider)
          .record(
            output: output,
            config: settings.imageGenerationApi,
            originalPrompt: originalPrompt,
            sentPrompt: sentPrompt,
            revisedPrompt: revisedPrompt,
            conversationId: convoId,
            messageId: messageId,
            references: references,
            parentGenerationId: parentGenerationId,
          );
    } catch (e) {
      // A local archive error must never discard an already paid image.
      _upsertSearchActivity(
        convoId,
        messageId,
        SearchActivity(
          kind: SearchActivityKind.image,
          query: '保存生图版本记录',
          status: SearchActivityStatus.failed,
          error: '图片仍保留在会话中；记录保存失败：$e',
        ),
      );
    }
  }

  /// Tool-capable config for the "搜索大脑" planner, or null when the chosen
  /// model cannot do function calling (the caller then falls back to a plain
  /// single-shot search).
  LlmConfig? _searchBrainConfig(SettingsState settings) {
    final config = settings.config.copyWith(
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
    activity = activity.copyWith(
      roundId: activity.roundId ?? _run?.currentRoundId,
    );
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return; // conversation was deleted mid-stream
    var convo = _s.conversations[idx];
    // Count actual search steps, including planner rounds and hosted events.
    final existingMessage = convo.messages
        .where((m) => m.id == msgId)
        .firstOrNull;
    if (activity.toolName == null &&
        (activity.kind == SearchActivityKind.search ||
            activity.kind == SearchActivityKind.fetch)) {
      // Search/fetch are safe to repeat and need no model planning to recover.
      activity = activity.copyWith(
        toolName: activity.kind == SearchActivityKind.search
            ? 'web_search'
            : 'fetch_url',
        toolArguments: jsonEncode({
          activity.kind == SearchActivityKind.search ? 'query' : 'url':
              activity.query,
        }),
      );
    }
    if ((activity.kind == SearchActivityKind.search ||
            (activity.kind == SearchActivityKind.fetch &&
                !_execution.isExecutingTool)) &&
        activity.status == SearchActivityStatus.running &&
        !(existingMessage?.searchActivities.any((a) => a.id == activity.id) ??
            false) &&
        ((!_execution.isExecutingTool &&
                !(_execution.budget?.takeTool() ?? true)) ||
            (activity.kind == SearchActivityKind.search &&
                !(_execution.budget?.takeSearch() ?? true)))) {
      activity = activity.copyWith(
        status: SearchActivityStatus.failed,
        error: _execution.budget?.reason ?? '搜索预算已用完',
      );
      // Exhaustion flushes buffered text synchronously; keep that new state.
      convo =
          _s.conversations.where((c) => c.id == convoId).firstOrNull ?? convo;
    }
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
        return activity.copyWith(
          contentOffset: existing.contentOffset,
          reasoningOffset: existing.reasoningOffset,
          roundId: existing.roundId,
          interrupted: activity.interrupted || existing.interrupted,
          startedAt: existing.startedAt,
          finishedAt: activity.status == SearchActivityStatus.running
              ? null
              : activity.finishedAt ?? existing.finishedAt ?? DateTime.now(),
          toolName: existing.toolName,
          toolArguments: existing.toolArguments,
          resultText: existing.resultText,
          retryOfId: existing.retryOfId,
        );
      }
    }
    return activity.copyWith(
      contentOffset: message.content.runes.length,
      reasoningOffset: message.reasoning.length,
      startedAt: activity.startedAt ?? DateTime.now(),
      finishedAt: activity.status == SearchActivityStatus.running
          ? null
          : DateTime.now(),
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
