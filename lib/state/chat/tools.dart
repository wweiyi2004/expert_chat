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
  }) async {
    final out = <LlmRequestMessage>[];
    try {
      for (var callIndex = 0; callIndex < toolCalls.length; callIndex++) {
        final call = toolCalls[callIndex];
        final toolCallId = call.id ?? '';
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
        String toolContent;
        if (callIndex >= maxCallsPerRound) {
          // Every requested call still gets a protocol-valid tool response, but
          // an untrusted/misbehaving model cannot fan out an unbounded number
          // of network requests in one turn.
          toolContent = '本轮最多执行 $maxCallsPerRound 次工具调用；其余请求已跳过。';
        } else if (call.name == ToolEngine.webSearchTool.name) {
          toolContent = await _runWebSearchTool(
            call,
            settings,
            fallbackSearchQuery,
            convoId,
            assistantId,
            citations,
            cancelToken,
            clientSearchBackend: clientSearchBackend,
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
            clientSearchBackend: clientSearchBackend,
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
        } else if (call.name == VisionTools.analyzeImageToolName) {
          toolContent = await _runAnalyzeImageTool(
            call,
            settings: settings,
            convoId: convoId,
            assistantId: assistantId,
            sources: _visionAttachmentsFor(
              _s.conversations.firstWhere(
                (c) => c.id == convoId,
                orElse: () => Conversation(id: convoId),
              ),
            ),
            cancelToken: cancelToken,
          );
        } else if (call.name == DocumentEditTools.inspectDocumentToolName) {
          toolContent = _runInspectDocumentTool(
            call,
            sources: editableAttachments,
            convoId: convoId,
            assistantId: assistantId,
          );
        } else if (call.name == DocumentEditTools.editDocumentToolName) {
          toolContent = await _runEditDocumentTool(
            call,
            settings: settings,
            convoId: convoId,
            assistantId: assistantId,
            sources: editableAttachments,
            cancelToken: cancelToken,
          );
        } else if (call.name == DocumentEditTools.convertDocumentToolName) {
          toolContent = await _runConvertDocumentTool(
            call,
            settings: settings,
            convoId: convoId,
            assistantId: assistantId,
            sources: editableAttachments,
            cancelToken: cancelToken,
          );
        } else if (call.name != null &&
            settings.routedMcpTool(call.name!) != null) {
          toolContent = await _runMcpPassthroughTool(
            call,
            settings: settings,
            convoId: convoId,
            assistantId: assistantId,
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
      _set(
        _s.copyWith(
          isSearching: false,
          isGeneratingImage: false,
          isProcessingDocument: false,
        ),
      );
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
    CancelToken cancelToken, {
    SearchBackend clientSearchBackend = SearchBackend.duckduckgo,
  }) async {
    final query = _searchQueryFromArgs(call.argumentsJson, fallbackSearchQuery);
    try {
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: clientSearchBackend,
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
      if (isCancelError(e)) return '搜索已取消。';
      _setScopedError(describeError(e), convoId: convoId);
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
    CancelToken cancelToken, {
    SearchBackend clientSearchBackend = SearchBackend.duckduckgo,
  }) async {
    final url = _urlFromArgs(call.argumentsJson);
    if (url == null) {
      final activity = _beginCapabilityTrace(
        convoId: convoId,
        assistantId: assistantId,
        kind: SearchActivityKind.fetch,
        query: 'fetch_url',
      );
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: '无效 URL',
      );
      return '无效的 URL 参数；请提供完整的 http(s) 网址。';
    }
    if (!allowedFetchUrls.contains(_fetchUrlKey(url))) {
      final activity = _beginCapabilityTrace(
        convoId: convoId,
        assistantId: assistantId,
        kind: SearchActivityKind.fetch,
        query: url,
      );
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: '已拒绝读取',
      );
      return '已拒绝读取：fetch_url 只能访问用户在本轮消息中明确提供的网址。';
    }
    try {
      // fetch_url only needs the page client; backend choice is irrelevant as
      // long as it is not the provider-hosted marker (which refuses client ops).
      final engine = ref.read(toolEngineFactoryProvider)(
        backend: clientSearchBackend.isProviderHosted
            ? SearchBackend.duckduckgo
            : clientSearchBackend,
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
      if (isCancelError(e)) return '网页读取已取消。';
      _setScopedError(describeError(e), convoId: convoId);
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

  List<Attachment> _visionAttachmentsFor(Conversation convo) {
    final out = <Attachment>[];
    final seen = <String>{};
    for (final message in convo.activePath) {
      if (message.role != MessageRole.user) continue;
      for (final a in message.attachments) {
        if (!a.isImage || !a.hasImageData) continue;
        if (!seen.add(a.id)) continue;
        out.add(a);
      }
    }
    return out;
  }

  Future<String> _runAnalyzeImageTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async {
    if (!settings.visionConfigured) {
      final activity = _beginCapabilityTrace(
        convoId: convoId,
        assistantId: assistantId,
        kind: SearchActivityKind.vision,
        query: '识图',
      );
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: '未配置视觉 API',
      );
      return '未配置视觉 API，无法识图。';
    }
    final args = VisionTools.parseArgs(call.argumentsJson);
    final image = VisionTools.pickImage(sources, args.attachmentName);
    if (image == null) {
      final names = VisionTools.availableNames(sources);
      final activity = _beginCapabilityTrace(
        convoId: convoId,
        assistantId: assistantId,
        kind: SearchActivityKind.vision,
        query: args.attachmentName.isNotEmpty ? args.attachmentName : '识图',
      );
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: '没有可识图附件',
      );
      if (args.attachmentName.isNotEmpty) {
        return '找不到图片「${args.attachmentName}」。可用： $names';
      }
      return '本轮没有可识图的图片附件。';
    }
    final text = await _analyzeImageWithVisionApi(
      settings: settings,
      image: image,
      question: args.resolvedQuestion,
      convoId: convoId,
      assistantId: assistantId,
      cancelToken: cancelToken,
    );
    if (text.isEmpty) {
      return '识图服务没有返回可用内容。';
    }
    return '【图片：${image.name}】\n$text';
  }

  Future<String> _analyzeImageWithVisionApi({
    required SettingsState settings,
    required Attachment image,
    required String question,
    required String convoId,
    required String assistantId,
    required CancelToken cancelToken,
  }) async {
    final activity = SearchActivity(
      kind: SearchActivityKind.vision,
      query: image.name,
    );
    _upsertSearchActivity(convoId, assistantId, activity);
    try {
      final buf = StringBuffer();
      await for (final chunk
          in ref
              .read(llmProvider)
              .streamChat(
                config: settings.visionConfig,
                cancelToken: cancelToken,
                messages: [
                  const LlmRequestMessage(
                    role: MessageRole.system,
                    content:
                        '你是视觉理解助手。只根据图片中可见内容作答，不要编造看不到的文字或物体。'
                        '用简洁中文；若图中有文字请如实转录。',
                  ),
                  LlmRequestMessage(
                    role: MessageRole.user,
                    content: question,
                    imageDataUrls: [image.imageDataUrl],
                  ),
                ],
              )) {
        if (cancelToken.isCancelled) break;
        if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
          buf.write(chunk.contentDelta);
        }
      }
      final text = buf.toString().trim();
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: text.isEmpty
              ? SearchActivityStatus.failed
              : SearchActivityStatus.done,
          resultCount: text.isEmpty ? 0 : 1,
          error: text.isEmpty ? '空结果' : null,
        ),
      );
      return text;
    } catch (e) {
      if (isCancelError(e) || cancelToken.isCancelled) {
        _upsertSearchActivity(
          convoId,
          assistantId,
          activity.copyWith(status: SearchActivityStatus.failed, error: '已取消'),
        );
        return '识图已取消。';
      }
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: describeError(e),
        ),
      );
      _setScopedError(describeError(e), convoId: convoId);
      return '识图失败：$e';
    }
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
          if (isCancelError(e) || cancelToken.isCancelled) {
            return (ok: false, error: null);
          }
          // Fall through with the scrubbed draft.
        }
      }
    }
    final activity = SearchActivity(
      kind: SearchActivityKind.image,
      query: '配图',
    );
    _upsertSearchActivity(convoId, assistantId, activity);
    if (_s.isStreaming) {
      _set(
        _s.copyWith(
          isGeneratingImage: true,
          isSearching: false,
          isProcessingDocument: false,
        ),
      );
    }
    if (prompt.trim().isEmpty) {
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: '生图提示词为空',
        ),
      );
      if (_s.isGeneratingImage) {
        _set(_s.copyWith(isGeneratingImage: false));
      }
      return (ok: false, error: '生图提示词为空。');
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
        _upsertSearchActivity(
          convoId,
          assistantId,
          activity.copyWith(status: SearchActivityStatus.failed, error: '已取消'),
        );
        return (ok: false, error: null);
      }
      final sizeBytes = generated.base64 == null
          ? 0
          : (generated.base64!.length * 3 / 4).round();
      final attachment = Attachment(
        name: libraryGeneratedImageName(
          prompt: prompt,
          mimeType: generated.mimeType,
        ),
        mimeType: generated.mimeType,
        sizeBytes: sizeBytes,
        imageBase64: generated.base64,
        remoteUrl: generated.remoteUrl,
      );
      _appendAssistantAttachment(convoId, assistantId, attachment);
      unawaited(_importImageToLibrary(attachment));
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.done,
          resultCount: 1,
          items: [SearchActivityItem(title: attachment.name)],
        ),
      );
      return (ok: true, error: null);
    } catch (e) {
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: isCancelError(e) || cancelToken.isCancelled
              ? '已取消'
              : describeError(e),
        ),
      );
      if (isCancelError(e) || cancelToken.isCancelled) {
        return (ok: false, error: null);
      }
      return (ok: false, error: describeError(e));
    } finally {
      if (_s.isGeneratingImage) {
        _set(_s.copyWith(isGeneratingImage: false));
      }
    }
  }

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

  Future<String> _runMcpPassthroughTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required CancelToken cancelToken,
  }) async {
    final exposedName = call.name ?? '';
    final routed = settings.routedMcpTool(exposedName);
    final name = routed?.originalName ?? exposedName;
    final activity = _beginCapabilityTrace(
      convoId: convoId,
      assistantId: assistantId,
      kind: SearchActivityKind.mcp,
      query: exposedName,
    );
    Map<String, dynamic> arguments = const {};
    try {
      final trimmed = call.argumentsJson.trim();
      final decoded = jsonDecode(trimmed.isEmpty ? '{}' : trimmed);
      if (decoded is! Map) {
        _finishCapabilityTrace(
          activity,
          convoId: convoId,
          assistantId: assistantId,
          ok: false,
          error: '参数必须是对象',
        );
        return 'MCP 工具 $exposedName 参数必须是对象';
      }
      arguments = Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: error.message,
      );
      return 'MCP 工具 $exposedName 参数不是合法 JSON：${error.message}';
    }
    try {
      final client = ref.read(documentServiceClientProvider);
      final result = await client.callDiscoveredTool(
        connection: routed == null
            ? settings.gatewayConnection
            : settings.connectionForRouted(routed),
        name: name,
        arguments: arguments,
        cancelToken: cancelToken,
      );
      if (!_s.isStreaming) {
        _upsertSearchActivity(
          convoId,
          assistantId,
          activity.copyWith(status: SearchActivityStatus.failed, error: '已取消'),
        );
        return 'MCP 工具 $name 已取消。';
      }
      final file = result.file;
      if (file != null) {
        _appendAssistantAttachment(
          convoId,
          assistantId,
          Attachment(
            name: file.filename,
            mimeType: file.contentType,
            sizeBytes: file.bytes.length,
            text: '（MCP Server 已返回文件，可下载）',
            imageBase64: base64Encode(file.bytes),
          ),
        );
      }
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.done,
          resultCount: file == null ? 1 : 1,
          items: [if (file != null) SearchActivityItem(title: file.filename)],
        ),
      );
      final text = result.text.trim();
      if (text.isNotEmpty) return text;
      if (file != null) {
        return 'MCP 工具 $name 已返回文件「${file.filename}」，已附在本轮回复中。';
      }
      return 'MCP 工具 $name 已执行，无文本结果。';
    } on DocumentServiceException catch (error) {
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: isCancelError(error) ? '已取消' : error.message,
        ),
      );
      if (isCancelError(error)) return 'MCP 工具 $name 已取消。';
      _setScopedError(error.message, convoId: convoId);
      return 'MCP 工具 $name 失败：${error.message}';
    } catch (error) {
      _upsertSearchActivity(
        convoId,
        assistantId,
        activity.copyWith(
          status: SearchActivityStatus.failed,
          error: isCancelError(error) ? '已取消' : describeError(error),
        ),
      );
      if (isCancelError(error)) return 'MCP 工具 $name 已取消。';
      _setScopedError(describeError(error), convoId: convoId);
      return 'MCP 工具 $name 失败：$error';
    }
  }

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

  String _runInspectDocumentTool(
    ToolCall call, {
    required List<Attachment> sources,
    required String convoId,
    required String assistantId,
  }) {
    final activity = _beginCapabilityTrace(
      convoId: convoId,
      assistantId: assistantId,
      kind: SearchActivityKind.document,
      query: 'inspect_document',
    );
    try {
      final args = DocumentEditTools.parseInspectDocumentArgs(
        call.argumentsJson,
      );
      final source = _pickDocumentSource(sources, args.attachmentName);
      if (source == null) {
        final names = [
          for (final a in sources)
            if (a.isEditableDocument) a.name,
        ];
        _finishCapabilityTrace(
          activity,
          convoId: convoId,
          assistantId: assistantId,
          ok: false,
          error: '没有可检查的附件',
        );
        return names.isEmpty
            ? '本轮没有可检查的附件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv）。'
            : '找不到附件「${args.attachmentName}」。本轮可用：${names.join("、")}';
      }
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: true,
        items: [SearchActivityItem(title: source.name)],
      );
      return DocumentEditTools.describeAttachmentForInspect(
        name: source.name,
        format: source.documentPatchFormat,
        mimeType: source.mimeType,
        sizeBytes: source.sizeBytes,
        truncated: source.truncated,
        hasBytes: source.hasDownloadableBytes,
        text: source.text,
      );
    } on DocumentPatchException catch (e) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: e.message,
      );
      return '检查参数无效：${e.message}';
    }
  }

  Future<String> _runEditDocumentTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async {
    final activity = _beginCapabilityTrace(
      convoId: convoId,
      assistantId: assistantId,
      kind: SearchActivityKind.document,
      query: 'edit_document',
    );
    String fail(String error, String message) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: error,
      );
      return message;
    }

    if (!settings.supportsDocumentEdit) {
      return fail('MCP Server 未配置', 'MCP Server 未配置或不支持文档编辑：请在设置中连接并发现 Tools。');
    }
    try {
      final args = DocumentEditTools.parseEditDocumentArgs(call.argumentsJson);
      final source = _pickDocumentSource(sources, args.attachmentName);
      if (source == null) {
        final names = [
          for (final a in sources)
            if (a.isEditableDocument ||
                a.name.toLowerCase().endsWith('.xlsx') ||
                a.name.toLowerCase().endsWith('.docx') ||
                a.name.toLowerCase().endsWith('.pptx') ||
                a.name.toLowerCase().endsWith('.txt') ||
                a.name.toLowerCase().endsWith('.md') ||
                a.name.toLowerCase().endsWith('.csv') ||
                a.name.toLowerCase().endsWith('.tsv'))
              a.name,
        ];
        return fail(
          '没有可编辑附件',
          names.isEmpty
              ? '本轮没有可编辑附件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv，需重新上传并保留原文件）。'
              : '找不到附件「${args.attachmentName}」。本轮可用：${names.join("、")}',
        );
      }
      if (!source.hasDownloadableBytes) {
        return fail(
          '未保留原始文件',
          '附件「${source.name}」未保留原始文件字节，无法提交 MCP 文档工具。请重新上传。',
        );
      }
      final expectedFormat = source.documentPatchFormat;
      if (expectedFormat != null &&
          args.patch.format.toLowerCase() != expectedFormat) {
        return fail(
          '补丁格式不一致',
          '补丁 format="${args.patch.format}" 与附件「${source.name}」'
              '（$expectedFormat）不一致，请修正后重试。',
        );
      }
      // Truncated attachments only expose a prefix to the model; set_text would
      // rewrite the full server-side file from that partial view and drop the tail.
      if (source.truncated && args.patch.hasSetTextOp) {
        return fail(
          '截断文件禁止整文件覆写',
          '附件「${source.name}」内容已截断（仅前缀进入模型上下文），'
              '禁止使用 set_text 整文件覆写，否则会丢失未展示部分。'
              '请改用 replace_text，或上传更短的文件后重试。',
        );
      }
      late final Uint8List fileBytes;
      try {
        fileBytes = Uint8List.fromList(base64Decode(source.imageBase64!));
      } catch (_) {
        return fail('数据损坏', '附件「${source.name}」数据损坏，无法编辑。');
      }

      final client = ref.read(documentServiceClientProvider);
      final result = await client.edit(
        connection: settings.gatewayConnection,
        fileBytes: fileBytes,
        filename: source.name,
        patch: args.patch,
        cancelToken: cancelToken,
      );
      if (!_s.isStreaming) {
        return fail('已取消', '文档编辑已取消。');
      }

      final out = Attachment(
        name: result.filename,
        mimeType: result.contentType,
        sizeBytes: result.bytes.length,
        text: '（MCP Server 已完成文档修改，可下载）',
        imageBase64: base64Encode(result.bytes),
      );
      _appendAssistantAttachment(convoId, assistantId, out);
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: true,
        items: [SearchActivityItem(title: result.filename)],
      );
      final kb = (result.bytes.length / 1024).toStringAsFixed(1);
      return '已生成修改后的文件「${result.filename}」（$kb KB），'
          '已附在本轮回复中，请点击附件下载。';
    } on DocumentPatchException catch (e) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: e.message,
      );
      return '补丁无效：${e.message}';
    } on DocumentServiceException catch (e) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: isCancelError(e) ? '已取消' : e.message,
      );
      if (isCancelError(e)) return '文档编辑已取消。';
      _setScopedError(e.message, convoId: convoId);
      return '文档编辑失败：${e.message}';
    } catch (e) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: isCancelError(e) ? '已取消' : describeError(e),
      );
      if (isCancelError(e)) return '文档编辑已取消。';
      _setScopedError(describeError(e), convoId: convoId);
      return '文档编辑失败：$e';
    }
  }

  Future<String> _runConvertDocumentTool(
    ToolCall call, {
    required SettingsState settings,
    required String convoId,
    required String assistantId,
    required List<Attachment> sources,
    required CancelToken cancelToken,
  }) async {
    final activity = _beginCapabilityTrace(
      convoId: convoId,
      assistantId: assistantId,
      kind: SearchActivityKind.document,
      query: 'convert_document',
    );
    String fail(String error, String message) {
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: false,
        error: error,
      );
      return message;
    }

    if (!settings.supportsDocumentConvert) {
      return fail('MCP Server 未配置', 'MCP Server 未配置或不支持格式转换：请在设置中连接并发现 Tools。');
    }
    try {
      final args = DocumentEditTools.parseConvertDocumentArgs(
        call.argumentsJson,
      );
      final source = _pickDocumentSource(sources, args.attachmentName);
      if (source == null) {
        final names = [
          for (final a in sources)
            if (a.isEditableDocument) a.name,
        ];
        return fail(
          '没有可转换附件',
          names.isEmpty
              ? '本轮没有可转换附件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv，需重新上传）。'
              : '找不到附件「${args.attachmentName}」。本轮可用：${names.join("、")}',
        );
      }
      if (!source.hasDownloadableBytes) {
        return fail('未保留原始文件', '附件「${source.name}」未保留原始文件字节，无法转换。请重新上传。');
      }
      final srcFmt = source.documentPatchFormat;
      if (srcFmt == null) {
        return fail('不是可转换格式', '附件「${source.name}」不是可转换格式。');
      }
      if (!DocumentConvert.canConvert(srcFmt, args.targetFormat)) {
        final targets = DocumentConvert.targetsFor(srcFmt).join(', ');
        return fail(
          '不支持的转换',
          '不支持 $srcFmt → ${args.targetFormat}。'
              '「${source.name}」可转为：$targets',
        );
      }
      late final Uint8List fileBytes;
      try {
        fileBytes = Uint8List.fromList(base64Decode(source.imageBase64!));
      } catch (_) {
        return fail('数据损坏', '附件「${source.name}」数据损坏，无法转换。');
      }

      final client = ref.read(documentServiceClientProvider);
      final result = await client.convert(
        connection: settings.gatewayConnection,
        fileBytes: fileBytes,
        filename: source.name,
        targetFormat: args.targetFormat,
        outputFilename: args.outputFilename,
        cancelToken: cancelToken,
      );
      if (!_s.isStreaming) {
        return fail('已取消', '文档转换已取消。');
      }

      final out = Attachment(
        name: result.filename,
        mimeType: result.contentType,
        sizeBytes: result.bytes.length,
        text: '（MCP Server 已完成格式转换，可下载）',
        imageBase64: base64Encode(result.bytes),
      );
      _appendAssistantAttachment(convoId, assistantId, out);
      _finishCapabilityTrace(
        activity,
        convoId: convoId,
        assistantId: assistantId,
        ok: true,
        items: [SearchActivityItem(title: result.filename)],
      );
      final kb = (result.bytes.length / 1024).toStringAsFixed(1);
      return '已将「${source.name}」转换为「${result.filename}」（$kb KB），'
          '已附在本轮回复中，请点击附件右侧下载图标保存。';
    } on DocumentPatchException catch (e) {
      return fail('转换参数无效', '转换参数无效：${e.message}');
    } on DocumentServiceException catch (e) {
      if (isCancelError(e)) return fail('已取消', '文档转换已取消。');
      _setScopedError(e.message, convoId: convoId);
      return fail(e.message, '文档转换失败：${e.message}');
    } catch (e) {
      if (isCancelError(e)) return fail('已取消', '文档转换已取消。');
      _setScopedError(describeError(e), convoId: convoId);
      return fail(describeError(e), '文档转换失败：$e');
    }
  }

  Attachment? _pickDocumentSource(
    List<Attachment> sources,
    String? attachmentName,
  ) {
    final docs = [
      for (final a in sources)
        if (a.isEditableDocument ||
            a.name.toLowerCase().endsWith('.xlsx') ||
            a.name.toLowerCase().endsWith('.docx') ||
            a.name.toLowerCase().endsWith('.pptx') ||
            a.name.toLowerCase().endsWith('.txt') ||
            a.name.toLowerCase().endsWith('.md') ||
            a.name.toLowerCase().endsWith('.csv') ||
            a.name.toLowerCase().endsWith('.tsv'))
          a,
    ];
    if (docs.isEmpty) return null;
    final want = attachmentName?.trim();
    if (want != null && want.isNotEmpty) {
      for (final a in docs) {
        if (a.name == want || a.name.toLowerCase() == want.toLowerCase()) {
          return a;
        }
      }
      return null;
    }
    if (docs.length == 1) return docs.first;
    for (final a in docs) {
      if (a.isEditableDocument) return a;
    }
    return docs.first;
  }

  /// Uses the deep-think config to rewrite [userPrompt] into a stronger
  /// text-to-image prompt. Returns the cleaned prompt text (may be empty if
  /// the model returned nothing useful — caller falls back to raw).
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
      reasoningEffort: _s.reasoningEffort,
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
    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$', multiLine: true);
    final m = fence.firstMatch(text);
    if (m != null) text = (m.group(1) ?? '').trim();
    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'")) ||
        (text.startsWith('“') && text.endsWith('”'))) {
      text = text.substring(1, text.length - 1).trim();
    }
    return text;
  }
}
