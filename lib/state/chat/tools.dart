part of '../chat_controller.dart';

mixin ChatTools on ChatMutations {
  Future<List<LlmRequestMessage>> _executeToolCalls({
    required List<ToolCall> toolCalls,
    int maxCallsPerRound = _maxToolCallsPerRound,
    required SettingsState settings,
    required String fallbackSearchQuery,
    required String convoId,
    required String assistantId,
    required List<Citation> citations,
    required Set<String> allowedFetchUrls,
    required CancelToken cancelToken,
    required _TurnImageBudget imageBudget,
    CharacterCard? imageCharacter,
    SearchBackend clientSearchBackend = SearchBackend.duckduckgo,
    List<Attachment> editableAttachments = const [],
    bool canSeeToolImages = false,
  }) async {
    var priorActivities = <String>{};
    Attachment? latestToolImage;
    String? latestToolImageCallId;
    try {
      final replies = await ToolCallRunner(_execution).run(
        calls: toolCalls,
        maxCalls: maxCallsPerRound,
        cancelToken: cancelToken,
        onStart: (call) {
          if (!ref.mounted) return;
          priorActivities =
              _messageById(
                convoId,
                assistantId,
              )?.searchActivities.map((a) => a.id).toSet() ??
              <String>{};
          // Per-tool composer hints — never reuse "正在联网搜索" for image/docs.
          if (_s.isStreaming) {
            final searching =
                call.name == ToolEngine.webSearchTool.name ||
                call.name == ToolEngine.fetchUrlTool.name;
            final generating = call.name == ToolEngine.generateImageTool.name;
            final processingDocument =
                call.name == DocumentEditTools.inspectDocumentToolName ||
                call.name == DocumentEditTools.editDocumentToolName ||
                call.name == DocumentEditTools.convertDocumentToolName ||
                settings.modelDocumentMcpTools.any(
                  (tool) => tool.name == call.name,
                );
            _set(
              _s.copyWith(
                isSearching: searching,
                isGeneratingImage: generating,
                isProcessingDocument: processingDocument,
              ),
            );
          }
        },
        execute: (call) async {
          if (call.name == ToolEngine.webSearchTool.name ||
              call.name == ToolEngine.fetchUrlTool.name) {
            return await _runSearchTool(
              call,
              settings: settings,
              fallbackSearchQuery: fallbackSearchQuery,
              convoId: convoId,
              assistantId: assistantId,
              citations: citations,
              allowedFetchUrls: allowedFetchUrls,
              cancelToken: cancelToken,
              backend: clientSearchBackend,
            );
          } else if (call.name == ToolEngine.generateImageTool.name) {
            return await _runGenerateImageTool(
              call,
              settings: settings,
              convoId: convoId,
              assistantId: assistantId,
              imageBudget: imageBudget,
              imageCharacter: imageCharacter,
              userText: fallbackSearchQuery,
              cancelToken: cancelToken,
            );
          } else if (call.name == VisionTools.analyzeImageToolName) {
            return await _runAnalyzeImageTool(
              call,
              settings: settings,
              convoId: convoId,
              assistantId: assistantId,
              sources: VisionTools.attachmentsFor(
                _s.conversations.firstWhere(
                  (c) => c.id == convoId,
                  orElse: () => Conversation(id: convoId),
                ),
              ),
              cancelToken: cancelToken,
            );
          } else if (call.name == DocumentEditTools.inspectDocumentToolName) {
            return _runInspectDocumentTool(
              call,
              sources: editableAttachments,
              convoId: convoId,
              assistantId: assistantId,
            );
          } else if (call.name == DocumentEditTools.editDocumentToolName) {
            return await _runEditDocumentTool(
              call,
              settings: settings,
              convoId: convoId,
              assistantId: assistantId,
              sources: editableAttachments,
              cancelToken: cancelToken,
            );
          } else if (call.name == DocumentEditTools.convertDocumentToolName) {
            return await _runConvertDocumentTool(
              call,
              settings: settings,
              convoId: convoId,
              assistantId: assistantId,
              sources: editableAttachments,
              cancelToken: cancelToken,
            );
          } else if (call.name != null &&
              settings.routedMcpTool(call.name!) != null) {
            final result = await _runMcpPassthroughTool(
              call,
              settings: settings,
              convoId: convoId,
              assistantId: assistantId,
              cancelToken: cancelToken,
              onImage: (image) {
                latestToolImage = image;
                latestToolImageCallId = call.id;
              },
            );
            if (latestToolImage != null && !canSeeToolImages) {
              return '$result\n当前聊天模型不支持读取截图。请使用支持视觉的模型，或使用控件树等文本观察。';
            }
            return result;
          } else {
            return '不支持的工具：${call.name ?? 'unknown'}';
          }
        },
        onResult: (call, content) {
          if (!ref.mounted) return;
          _recordToolResult(
            convoId,
            assistantId,
            call,
            content,
            priorActivities,
          );
        },
      );
      if (latestToolImage != null &&
          canSeeToolImages &&
          !cancelToken.isCancelled &&
          !_execution.isCancelled) {
        replies.add(
          ToolImageContext.observation(
            latestToolImage!,
            callId: latestToolImageCallId,
          ),
        );
      }
      return replies;
    } finally {
      if (ref.mounted) {
        _set(
          _s.copyWith(
            isSearching: false,
            isGeneratingImage: false,
            isProcessingDocument: false,
          ),
        );
      }
    }
  }

  Future<String> _runSearchTool(
    ToolCall call, {
    required SettingsState settings,
    required String fallbackSearchQuery,
    required String convoId,
    required String assistantId,
    required List<Citation> citations,
    required Set<String> allowedFetchUrls,
    required CancelToken cancelToken,
    required SearchBackend backend,
  }) async {
    final result =
        await SearchToolExecutor(
          createEngine: ({required backend, required apiKey}) => ref.read(
            toolEngineFactoryProvider,
          )(backend: backend, apiKey: apiKey),
        ).execute(
          call: call,
          fallbackSearchQuery: fallbackSearchQuery,
          searchApiKey: settings.searchApiKey,
          maxResults: settings.searchMaxResults,
          backend: backend,
          citations: citations,
          allowedFetchUrls: allowedFetchUrls,
          cancelToken: cancelToken,
          onActivity: (activity) =>
              _upsertSearchActivity(convoId, assistantId, activity),
        );
    if (result.citationsChanged) {
      citations
        ..clear()
        ..addAll(result.citations);
      _setCitations(convoId, assistantId, List<Citation>.of(citations));
    }
    if (result.error != null) {
      _setScopedError(describeError(result.error!), convoId: convoId);
    }
    return result.content;
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
      final activity = _beginCapabilityTrace(
        convoId: convoId,
        assistantId: assistantId,
        kind: SearchActivityKind.image,
        query: '配图',
      );
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: '本轮已生成过图片',
      );
      return '本轮已生成过图片，每轮对话最多一张。';
    }
    if (!settings.imageGenerationConfigured) {
      final activity = _beginCapabilityTrace(
        convoId: convoId,
        assistantId: assistantId,
        kind: SearchActivityKind.image,
        query: '配图',
      );
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: '未配置图片生成 API',
      );
      return '未配置图片生成 API，无法配图。';
    }
    final args = DialogueImageExecutor.parseToolArgs(call.argumentsJson);
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
      countTool: false,
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

  VisionToolExecutor _visionExecutor(String convoId, String assistantId) =>
      VisionToolExecutor(
        getProvider: () => ref.read(llmProvider),
        onActivity: (activity) =>
            _upsertSearchActivity(convoId, assistantId, activity),
        checkBudget: () => (
          allowed:
              _execution.isExecutingTool ||
              (_execution.budget?.takeTool() ?? true),
          reason: _execution.budget?.reason,
        ),
      );

  String _applyVisionResult(VisionToolResult result, String convoId) {
    if (result.error != null) {
      _setScopedError(describeError(result.error!), convoId: convoId);
    }
    return result.content;
  }

  Future<String> _runAnalyzeImageTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async => _applyVisionResult(
    await _visionExecutor(convoId, assistantId).execute(
      call: call,
      config: settings.visionConfigured ? settings.visionConfig : null,
      sources: sources,
      cancelToken: cancelToken,
    ),
    convoId,
  );

  Future<String> _analyzeImageWithVisionApi({
    required SettingsState settings,
    required Attachment image,
    required String question,
    required String convoId,
    required String assistantId,
    required CancelToken cancelToken,
  }) async => _applyVisionResult(
    await _visionExecutor(convoId, assistantId).analyze(
      config: settings.visionConfig,
      image: image,
      question: question,
      cancelToken: cancelToken,
    ),
    convoId,
  );

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
    bool countTool = true,
  }) =>
      DialogueImageExecutor(
        getProvider: () => ref.read(mediaApiProvider),
        isActive: () => _s.isStreaming,
        checkBudget: () => (
          allowed: _execution.budget?.takeTool() ?? true,
          reason: _execution.budget?.reason,
        ),
        onActivity: (activity) =>
            _upsertSearchActivity(convoId, assistantId, activity),
        onGeneratingChanged: (generating) {
          if (generating && _s.isStreaming) {
            _set(
              _s.copyWith(
                isGeneratingImage: true,
                isSearching: false,
                isProcessingDocument: false,
              ),
            );
          } else if (!generating && _s.isGeneratingImage) {
            _set(_s.copyWith(isGeneratingImage: false));
          }
        },
        onGenerated: (output) async {
          _appendAssistantAttachment(convoId, assistantId, output.attachment);
          await _recordImageVersion(
            output: output.attachment,
            settings: settings,
            originalPrompt: userText,
            sentPrompt: output.sentPrompt,
            revisedPrompt: output.revisedPrompt,
            convoId: convoId,
            messageId: assistantId,
          );
        },
      ).execute(
        config: settings.imageGenerationConfigured
            ? settings.imageGenerationApi
            : null,
        apiKey: settings.imageGenerationApiKey,
        character: character,
        userText: userText,
        modelPrompt: modelPrompt,
        briefHint: briefHint,
        cancelToken: cancelToken,
        optimizePrompt: optimizeWithDeepThink && settings.config.isReady
            ? (prompt) => _optimizeImagePrompt(
                userPrompt: prompt,
                settings: settings,
                cancelToken: cancelToken,
                onReasoning: (_, _) {},
              )
            : null,
        countTool: countTool,
      );

  /// User attachments belonging to the turn that produced [assistantId]
  /// (walk parent chain to the nearest user message).
  ChatMessage? _parentUserForTurn(Conversation convo, String assistantId) {
    final byId = {for (final m in convo.messages) m.id: m};
    var cur = byId[assistantId];
    while (cur != null) {
      if (cur.role == MessageRole.user) return cur;
      final parentId = cur.parentId;
      if (parentId == null) break;
      cur = byId[parentId];
    }
    return null;
  }

  List<ChatMessage> _recentTurnsBefore(
    Conversation convo, {
    required String assistantId,
    String? excludeId,
  }) => [
    for (final message in convo.activePath)
      if (message.id != assistantId &&
          message.id != excludeId &&
          (message.role == MessageRole.user ||
              message.role == MessageRole.assistant))
        message,
  ];

  void _setTurnSkill(String convoId, String msgId, TurnSkillMark mark) {
    final idx = _s.conversations.indexWhere((c) => c.id == convoId);
    if (idx < 0) return;
    final convo = _s.conversations[idx];
    final messages = [
      for (final m in convo.messages)
        if (m.id == msgId) m.copyWith(turnSkill: mark) else m,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
  }

  List<Attachment> _userAttachmentsForTurn(
    Conversation working,
    String assistantId,
  ) {
    final byId = {for (final m in working.messages) m.id: m};
    var cur = byId[assistantId];
    // Also accept the latest user message if the assistant is a fresh placeholder.
    while (cur != null) {
      if (cur.role == MessageRole.user) {
        return List<Attachment>.unmodifiable(cur.attachments);
      }
      final parentId = cur.parentId;
      if (parentId == null) break;
      cur = byId[parentId];
    }
    for (var i = working.messages.length - 1; i >= 0; i--) {
      final m = working.messages[i];
      if (m.role == MessageRole.user && m.attachments.isNotEmpty) {
        return List<Attachment>.unmodifiable(m.attachments);
      }
    }
    return const [];
  }

  DocumentToolExecutor _documentToolExecutor(
    String convoId,
    String assistantId, {
    void Function(Attachment)? onMcpImage,
  }) => DocumentToolExecutor(
    getClient: () => ref.read(documentServiceClientProvider),
    isActive: () => ref.mounted && _s.isStreaming,
    onActivity: (activity) =>
        _upsertSearchActivity(convoId, assistantId, activity),
    onAttachment: (attachment) {
      _appendAssistantAttachment(convoId, assistantId, attachment);
      if (attachment.isImage && attachment.hasImageData) {
        onMcpImage?.call(attachment);
      }
    },
    onError: (error) => _setScopedError(error, convoId: convoId),
  );

  Future<String> _runMcpPassthroughTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required CancelToken cancelToken,
    void Function(Attachment)? onImage,
  }) {
    final exposedName = call.name ?? '';
    final routed = settings.routedMcpTool(exposedName);
    var connection = routed == null
        ? settings.gatewayConnection
        : settings.connectionForRouted(routed);
    if (routed?.serverId != null) {
      final latest = ref.read(settingsControllerProvider).value;
      final currentServer = latest?.gateway.customMcpServers
          .where((s) => s.id == routed!.serverId)
          .firstOrNull;
      if (currentServer == null ||
          !currentServer.enabled ||
          !currentServer.toolsDiscovered ||
          currentServer.computerUse != connection.computerUse ||
          currentServer.localProcess?.identity !=
              settings.connectionForRouted(routed!).localProcess?.identity) {
        return Future.value('MCP 服务已关闭或配置已变化，本次操作未执行。');
      }
      if (currentServer.computerUse &&
          _s.conversations
                  .where((c) => c.id == convoId)
                  .firstOrNull
                  ?.workMode !=
              true) {
        return Future.value('电脑操作仅在任务模式下执行。');
      }
      if (currentServer.computerUse &&
          _s.conversations
                  .where((c) => c.id == convoId)
                  .firstOrNull
                  ?.customMcpServerIds
                  .contains(currentServer.id) !=
              true) {
        return Future.value('此会话未选择该电脑操作服务。');
      }
      if (connection.allowForeground && !currentServer.allowForeground) {
        connection = GatewayConnection(
          config: connection.config,
          apiToken: connection.apiToken,
          tokenProvider: connection.tokenProvider,
          localProcess: connection.localProcess,
          computerUse: connection.computerUse,
        );
      }
    }
    return _documentToolExecutor(
      convoId,
      assistantId,
      onMcpImage: onImage,
    ).callMcp(
      call,
      name: routed?.originalName ?? exposedName,
      connection: connection,
      cancelToken: cancelToken,
    );
  }

  String _runInspectDocumentTool(
    ToolCall call, {
    required List<Attachment> sources,
    required String convoId,
    required String assistantId,
  }) => _documentToolExecutor(
    convoId,
    assistantId,
  ).inspect(call, sources: sources);

  Future<String> _runEditDocumentTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) => _documentToolExecutor(convoId, assistantId).edit(
    call,
    supported: settings.supportsDocumentEdit,
    connection: settings.gatewayConnection,
    sources: sources,
    cancelToken: cancelToken,
  );

  Future<String> _runConvertDocumentTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) => _documentToolExecutor(convoId, assistantId).convert(
    call,
    supported: settings.supportsDocumentConvert,
    connection: settings.gatewayConnection,
    sources: sources,
    cancelToken: cancelToken,
  );

  SearchActivity _beginCapabilityTrace({
    required String convoId,
    required String assistantId,
    required SearchActivityKind kind,
    required String query,
  }) {
    final activity = SearchActivity(kind: kind, query: query);
    _upsertSearchActivity(convoId, assistantId, activity);
    return activity;
  }

  void _finishCapabilityTrace(
    SearchActivity activity, {
    required String convoId,
    required String assistantId,
    required bool ok,
    String? error,
    List<SearchActivityItem> items = const [],
  }) {
    _upsertSearchActivity(
      convoId,
      assistantId,
      activity.copyWith(
        status: ok ? SearchActivityStatus.done : SearchActivityStatus.failed,
        resultCount: ok ? (items.isEmpty ? 1 : items.length) : 0,
        error: error,
        items: items,
      ),
    );
  }

  /// Uses the deep-think config to rewrite [userPrompt] into a stronger
  /// text-to-image prompt. Returns the cleaned prompt text (may be empty if
  /// the model returned nothing useful — caller falls back to raw).
  Future<String> _optimizeImagePrompt({
    required String userPrompt,
    required SettingsState settings,
    required CancelToken cancelToken,
    required void Function(String reasoning, int thinkingMillis) onReasoning,
  }) => ImagePromptOptimizer(getProvider: () => ref.read(llmProvider)).optimize(
    userPrompt: userPrompt,
    config: _configFor(settings),
    cancelToken: cancelToken,
    onReasoning: onReasoning,
  );
}
