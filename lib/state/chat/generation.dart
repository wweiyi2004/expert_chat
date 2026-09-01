part of '../chat_controller.dart';

mixin ChatGeneration on ChatStreaming {
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
    StoryGenerationIntent? storyIntent,
    CharacterCard? ensembleSpeaker,
    bool forceDocumentEdit = false,
  }) async {
    // The conversation was deleted while this turn was preflighting (awaiting
    // settings). Abandon the turn: re-inserting [working] here would resurrect
    // the deleted row both in memory and, via persistById, in the database.
    if (_deletedWhileStartingIds.contains(working.id)) return;
    final searchMode = _s.searchMode;
    final searchAllowed =
        searchMode != SearchMode.off &&
        searchQuery.trim().isNotEmpty &&
        !working.isStoryLike &&
        !working.isStudy;
    // Hosted web_search (DeepSeek Responses) when the user picked the provider
    // backend and the active model supports it. Otherwise the client tool /
    // pre-search path stays in charge.
    final useProviderSearch =
        searchAllowed &&
        settings.searchBackend.isProviderHosted &&
        config.capabilities.supportsServerWebSearch;
    final useWebSearchTool =
        searchAllowed &&
        !useProviderSearch &&
        config.capabilities.supportsTools;
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
        imageGenMode != ImageGenMode.off &&
        imageGenConfigured &&
        !working.isStudy;
    // Document edit: Linux service + editable file with retained bytes + tools.
    final turnUserAttachments = _userAttachmentsForTurn(working, assistantId);
    final editableDocuments = [
      for (final a in turnUserAttachments)
        if (a.isEditableDocument) a,
    ];
    final documentToolsAllowed =
        config.capabilities.supportsTools && editableDocuments.isNotEmpty;
    final useDocumentEditTool =
        settings.supportsDocumentEdit && documentToolsAllowed;
    final useDocumentConvertTool =
        settings.supportsDocumentConvert && documentToolsAllowed;
    final useDocumentInspectTool =
        (useDocumentEditTool || useDocumentConvertTool) && documentToolsAllowed;
    final forceDocTool = forceDocumentEdit && useDocumentEditTool;
    final mcpPassthroughTools = [
      if (config.capabilities.supportsTools && !forceDocTool)
        for (final tool in settings.modelMcpToolsFor(
          working.customMcpServerIds,
        ))
          McpHostTools.toSpec(tool),
    ];
    final turnImages = [
      for (final a in turnUserAttachments)
        if (a.isImage && a.hasImageData) a,
    ];
    final historyImages = _visionAttachmentsFor(working);
    final visionSources = [
      ...turnImages,
      for (final a in historyImages)
        if (!turnImages.any((t) => t.id == a.id)) a,
    ];
    final nativeVision =
        config.capabilities.supportsVision && visionSources.isNotEmpty;
    final visionToolWanted =
        !nativeVision && settings.visionConfigured && visionSources.isNotEmpty;
    final useVisionTool =
        visionToolWanted && config.capabilities.supportsTools && !forceDocTool;
    final needPreVision =
        visionToolWanted && !useVisionTool && turnImages.isNotEmpty;
    final toolSpecs = <ToolSpec>[
      if (useWebSearchTool && !forceDocTool) ToolEngine.webSearchTool,
      if (useFetchUrlTool && !forceDocTool) ToolEngine.fetchUrlTool,
      if (useVisionTool) VisionTools.analyzeImageTool,
      if (useDocumentInspectTool) DocumentEditTools.inspectDocumentTool,
      if (useDocumentEditTool) DocumentEditTools.editDocumentTool,
      // Conversion is never forced; offered whenever the MCP server has it.
      if (useDocumentConvertTool) DocumentEditTools.convertDocumentTool,
      ...mcpPassthroughTools,
    ];
    if (searchAllowed &&
        settings.searchBackend.isProviderHosted &&
        !config.capabilities.supportsServerWebSearch) {
      // Soft notice once per turn: official search only works on flash today.
      _setScopedError(
        '当前模型不支持提供商官方联网（需 DeepSeek V4），'
        '本轮将回退到客户端搜索后端。',
        convoId: working.id,
      );
    }
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
      storyIntent: storyIntent,
      ensembleSpeakerId: ensembleSpeaker?.id,
    );

    // One token covers the whole generation (search pre-step + all tool
    // rounds); stop() fires it.
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;

    // The user may have switched conversations while this turn was preflighting
    // (awaiting settings); don't yank focus back. The stream itself still
    // targets [working.id] and writes into it.
    final holdsFocus = _s.currentId == working.id || _s.currentId == null;
    // Side edits (rename, story-meta changes, cast updates) may have landed on
    // the live conversation during the same window; carry them over so the
    // snapshot below does not roll them back to the preflight-time values.
    // The message tree stays owned by [working]: it carries this turn's new
    // messages and branch links.
    var turnTarget = working;
    for (final c in _s.conversations) {
      if (c.id != working.id) continue;
      turnTarget = working.copyWith(
        title: c.title,
        participantIds: c.participantIds,
        localCast: c.localCast,
        worldInfoIds: c.worldInfoIds,
        outline: c.outline,
        authorNote: c.authorNote,
        plotCursor: c.plotCursor,
        venue: c.venue,
        targetTotalChars: c.targetTotalChars,
      );
      break;
    }
    _set(
      _s.copyWith(
        // Move the conversation to the top: it just got new activity, matching
        // the updatedAt-desc order used when loading from the DB. Also covers
        // the defensive case where [working] wasn't in the list yet.
        conversations: [
          turnTarget,
          ..._s.conversations.where((c) => c.id != working.id),
        ],
        currentId: holdsFocus ? working.id : _s.currentId,
        streamingConvoId: working.id,
        isSearching: false,
        isGeneratingImage: false,
        isProcessingDocument: false,
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
      await _persistence.persistById(working.id);
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
    // 2) planner-orchestrated web search only for models that cannot use tools
    // 3) 配图·强制 on tool-less models: one SFW image before the answer
    SearchContext? searchContext;
    var forceImageNote = '';
    // Auto: model may call once. Always: force the tool on tool-capable models.
    final useImageGenTool =
        imageGenWanted &&
        imageBudget.canGenerate &&
        config.capabilities.supportsTools &&
        (imageGenMode == ImageGenMode.auto ||
            imageGenMode == ImageGenMode.always);
    if (imageGenWanted &&
        imageGenMode == ImageGenMode.always &&
        !useImageGenTool &&
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
    if (useImageGenTool) {
      toolSpecs.add(ToolEngine.generateImageTool);
    }
    final enableTools = toolSpecs.isNotEmpty;
    // Tool-capable models can decide when the pasted link is relevant. Models
    // without function calling keep the deterministic pre-fetch fallback.
    final needPreFetch =
        directPageFetchAllowed && pastedUrls.isNotEmpty && !useFetchUrlTool;
    // Provider-hosted search is done inside the Responses stream. Tool-capable
    // models call web_search themselves; 联网·强制 becomes tool_choice.
    final needPreSearch =
        searchAllowed && !useProviderSearch && !useWebSearchTool;
    // When official search is unavailable, fall back to a free client backend
    // so the turn still has a search path without requiring a search key.
    final clientSearchBackend =
        settings.searchBackend.isProviderHosted && !useProviderSearch
        ? SearchBackend.duckduckgo
        : settings.searchBackend;
    if (needPreFetch || needPreSearch) {
      _set(
        _s.copyWith(
          isSearching: true,
          isGeneratingImage: false,
          isProcessingDocument: false,
        ),
      );
      // Live progress steps land on the assistant placeholder as they happen.
      void activitySink(SearchActivity activity) =>
          _upsertSearchActivity(working.id, assistantId, activity);
      try {
        final engine = ref.read(toolEngineFactoryProvider)(
          backend: clientSearchBackend,
          apiKey: settings.searchApiKey,
        );
        final citations = <Citation>[];
        final blocks = <String>[];

        if (needPreFetch) {
          try {
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
          } catch (e) {
            if (!isCancelError(e)) {
              _setScopedError(describeError(e), convoId: working.id);
            }
          }
        }

        if (needPreSearch && _s.isStreaming) {
          try {
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
          } catch (e) {
            if (!isCancelError(e)) {
              _setScopedError(describeError(e), convoId: working.id);
            }
          }
        }

        if (citations.isNotEmpty) {
          searchContext = SearchContext(
            contextText: blocks.join('\n'),
            citations: List.unmodifiable(citations),
          );
          _setCitations(working.id, assistantId, searchContext.citations);
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
    }

    // The user may have pressed stop during the (awaited) search; honor it.
    if (!_s.isStreaming) {
      await _persistence.persistSafely(working.id);
      // Drop our token like _streamAnswer's finally would, so a later stop()
      // or dispose cannot touch a stale one.
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
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
    var preVisionNote = '';
    if (needPreVision && _s.isStreaming) {
      final parts = <String>[];
      final question = searchQuery.trim().isEmpty
          ? VisionTools.defaultQuestion
          : searchQuery.trim();
      for (final image in turnImages) {
        final text = await _analyzeImageWithVisionApi(
          settings: settings,
          image: image,
          question: question,
          convoId: working.id,
          assistantId: assistantId,
          cancelToken: cancelToken,
        );
        if (text.isNotEmpty) {
          parts.add('【图片：${image.name}】\n$text');
        }
        if (!_s.isStreaming) break;
      }
      if (parts.isNotEmpty) {
        preVisionNote = '本轮附件图片已由识图服务分析（对话模型看不到像素）：\n${parts.join('\n\n')}';
      }
    }
    if (!_s.isStreaming) {
      await _persistence.persistSafely(working.id);
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      return;
    }

    final history = cur.activePath
        .where((m) => m.id != assistantId)
        .map(
          (m) => _toRequestMessage(
            m,
            vision: nativeVision,
            imageToolAvailable: useVisionTool,
          ),
        )
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

    // System prefix: story / ensemble use the assembler (no chat catalog
    // persona). Chat uses the per-turn skill. Study keeps its own prompt.
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
            labeled.add(
              _toRequestMessage(
                m,
                vision: nativeVision,
                imageToolAvailable: useVisionTool,
              ),
            );
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
        globalSystemPrompt: '',
        character: card,
        cast: cast,
        speakingAs: ensembleSpeaker,
        worldInfoPool: worldPool,
        conversation: promptConversation,
        historyPath: pathForScan,
        advancePlot: advancePlot,
        ensembleTurn: ensemble,
        directorMode: directorStory,
        intent: storyIntent,
      );
      if (prefix.worldInfoHits.isNotEmpty) {
        _setAppliedWorldInfo(working.id, assistantId, prefix.worldInfoHits);
      }
      // Stable story context stays ahead of generic memory/tool hints. The
      // assembler's turn-local action is appended after ordinary history.
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
      if (preVisionNote.isNotEmpty) {
        systemPrefix.add(
          LlmRequestMessage(role: MessageRole.system, content: preVisionNote),
        );
      }
      if (enableTools) {
        systemPrefix.add(
          LlmRequestMessage(
            role: MessageRole.system,
            content: _composeClientToolHint(
              searchMode: searchMode,
              imageGenMode: imageGenMode,
              useWebSearchTool: useWebSearchTool,
              useFetchUrlTool: useFetchUrlTool,
              useImageGenTool: useImageGenTool,
              useVisionTool: useVisionTool,
              useDocumentInspectTool: useDocumentInspectTool,
              useDocumentEditTool: useDocumentEditTool,
              useDocumentConvertTool: useDocumentConvertTool,
              forceDocTool: forceDocTool,
              workMode: working.workMode,
              imageCharacter: imageCharacter,
              mcpPassthroughTools: mcpPassthroughTools,
            ),
          ),
        );
      }
      history.insertAll(0, systemPrefix);
      history.addAll(prefix.postHistoryMessages);
    } else {
      ChatSkillRoute? skillRoute;
      if (cur.mode == ConversationMode.chat &&
          settings.chatSkills.enabled.isNotEmpty) {
        if (!settings.config.isReady) {
          skillRoute = ChatSkillRoute(
            skill: settings.chatSkills.fallback,
            source: ChatSkillSource.fallback,
          );
        } else {
          final parentUser = _parentUserForTurn(working, assistantId);
          skillRoute = await const ChatSkillRouter().route(
            userText: parentUser?.content ?? '',
            recent: _recentTurnsBefore(
              working,
              assistantId: assistantId,
              excludeId: parentUser?.id,
            ),
            catalog: settings.chatSkills,
            llm: ref.read(llmProvider),
            config: settings.config.copyWith(
              model: settings.active?.chatModel ?? settings.model,
            ),
            cancelToken: cancelToken,
          );
        }
        _setTurnSkill(
          working.id,
          assistantId,
          TurnSkillMark(
            id: skillRoute.skill.id,
            name: skillRoute.skill.name,
            source: skillRoute.source,
          ),
        );
      }
      if (cur.isStudy) {
        final studySystem = await _studySystemPrompt(cur);
        if (studySystem.isNotEmpty) {
          history.insert(
            0,
            LlmRequestMessage(role: MessageRole.system, content: studySystem),
          );
        }
      }
      if (memoryPrompt.isNotEmpty) {
        history.insert(
          0,
          LlmRequestMessage(role: MessageRole.system, content: memoryPrompt),
        );
      }
      final preset = chatPresetPrompt(
        mode: cur.mode,
        route: skillRoute,
        fallbackPrompt: settings.systemPrompt.trim(),
      );
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
      if (preVisionNote.isNotEmpty) {
        history.insert(
          0,
          LlmRequestMessage(role: MessageRole.system, content: preVisionNote),
        );
      }
      if (enableTools) {
        history.insert(
          0,
          LlmRequestMessage(
            role: MessageRole.system,
            content: _composeClientToolHint(
              searchMode: searchMode,
              imageGenMode: imageGenMode,
              useWebSearchTool: useWebSearchTool,
              useFetchUrlTool: useFetchUrlTool,
              useImageGenTool: useImageGenTool,
              useVisionTool: useVisionTool,
              useDocumentInspectTool: useDocumentInspectTool,
              useDocumentEditTool: useDocumentEditTool,
              useDocumentConvertTool: useDocumentConvertTool,
              forceDocTool: forceDocTool,
              workMode: working.workMode,
              imageCharacter: imageCharacter,
              mcpPassthroughTools: mcpPassthroughTools,
            ),
          ),
        );
      }
    }

    if (!_s.isStreaming) {
      await _persistence.persistSafely(working.id);
      // Drop our token like _streamAnswer's finally would.
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
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
      await _persistence.persistSafely(working.id);
      // Drop our token like _streamAnswer's finally would.
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      unawaited(
        GenerationNotify.onGenerationEnd(
          success: false,
          conversationTitle: working.title,
        ),
      );
      return;
    }

    final streamConfig = config.copyWith(
      serverWebSearch: useProviderSearch,
      forceServerWebSearch:
          useProviderSearch && searchMode == SearchMode.always,
    );
    final succeeded = await _streamAnswer(
      config: streamConfig,
      history: contextResult.messages,
      convoId: working.id,
      assistantId: assistantId,
      thinking: thinking,
      settings: settings,
      fallbackSearchQuery: searchQuery,
      enableTools: enableTools || useProviderSearch,
      toolSpecs: toolSpecs,
      initialCitations: searchContext?.citations ?? const <Citation>[],
      allowedFetchUrls: Set<String>.unmodifiable(allowedFetchUrls),
      cancelToken: cancelToken,
      imageBudget: imageBudget,
      imageCharacter: imageCharacter,
      failureOperation: failureOperation,
      clientSearchBackend: clientSearchBackend,
      forceToolName: forcedClientToolName(
        forceDocument: forceDocTool,
        forceImage: useImageGenTool && imageGenMode == ImageGenMode.always,
        forceClientSearch: useWebSearchTool && searchMode == SearchMode.always,
      ),
      workMode: working.workMode,
    );

    unawaited(
      GenerationNotify.onGenerationEnd(
        success: succeeded,
        conversationTitle: working.title,
        preview: _previewFor(working.id, assistantId),
        cancelled: !succeeded && _cancelStart,
      ),
    );

    // A successful "write next scene" action advances exactly one beat.
    // Length is pacing guidance only; it must never keep a dramatically
    // complete scene open just to satisfy an estimated character quota.
    if (succeeded && commitPlotAdvance && cur.isStory) {
      final latest = _s.conversations.firstWhere(
        (c) => c.id == working.id,
        orElse: () => cur,
      );
      if (latest.isStory) {
        final beats = latest.outlineBeats;
        final next = beats.isEmpty
            ? latest.plotCursor + 1
            : (latest.plotCursor + 1).clamp(0, beats.length);
        final updated = latest.copyWith(plotCursor: next);
        _set(_s.copyWith(conversations: _replace(updated)));
        await _persistence.persistSafely(working.id);
      }
    }
  }

  String _composeClientToolHint({
    required SearchMode searchMode,
    required ImageGenMode imageGenMode,
    required bool useWebSearchTool,
    required bool useFetchUrlTool,
    required bool useImageGenTool,
    required bool useVisionTool,
    required bool useDocumentInspectTool,
    required bool useDocumentEditTool,
    required bool useDocumentConvertTool,
    required bool forceDocTool,
    required bool workMode,
    required CharacterCard? imageCharacter,
    required List<ToolSpec> mcpPassthroughTools,
  }) {
    final hint = StringBuffer(ToolEngine.dateLine())..write('。');
    if (useWebSearchTool) {
      hint.write(
        searchMode == SearchMode.always
            ? '本轮必须调用 web_search。搜索关键词应自包含（把指代替换成具体名称，时效性问题带上年份）。'
            : '需要实时、最新或你不确定的事实时调用 web_search；'
                  '生图前若要核实真实事物的外观/标志也可先搜。'
                  '常识、闲聊、上下文已有的内容不要搜。'
                  '搜索关键词应自包含（把指代替换成具体名称，时效性问题带上年份）。',
      );
    }
    if (useFetchUrlTool) {
      hint.write('用户在本轮消息中给出的链接可用 fetch_url 读取。');
    }
    if (useImageGenTool) {
      if (imageCharacter != null) {
        hint.write(
          imageGenMode == ImageGenMode.always
              ? '本轮必须调用 generate_image，为角色「${imageCharacter.name}」配一张安全立绘（每轮最多一次）；'
                    '即使用户在写成人向内容，生图也只画干净角色形象，禁止色情提示词。'
              : '仅当用户明确要图，或立绘能明显帮助理解时，为角色「${imageCharacter.name}」调用 generate_image（每轮最多一次）；'
                    '不要给每句对白配装饰图。即使用户在写成人向内容，生图也只画干净角色形象，禁止色情提示词。',
        );
      } else {
        hint.write(
          imageGenMode == ImageGenMode.always
              ? '本轮必须调用 generate_image（每轮最多一次）；提示词必须 SFW，禁止色情内容。'
              : '仅当用户明确要求画图/配图/生成图片，或配图能明显帮助理解时调用 generate_image（每轮最多一次）。'
                    '不要给普通文字回答配装饰图。'
                    '画真实存在、你不确定外观的事物时，先 web_search 再根据搜索结果写 prompt。'
                    '提示词必须 SFW，禁止色情内容。',
        );
      }
    }
    if (useVisionTool) {
      hint.write(
        '用户上传了图片。你看不到像素，需要看图、读图中文字或回答图里的细节时，'
        '必须调用 analyze_image；attachment_name 用【图片：文件名】中的名字。',
      );
    }
    if (useDocumentInspectTool) {
      hint.write('改表格或不确定附件结构时，先调用 inspect_document 查看预览。');
    }
    if (useDocumentEditTool) {
      hint.write(
        forceDocTool
            ? '用户点击了「改文档」。你必须调用 edit_document，'
                  '给出完整 DocumentPatch（schema_version=1；format 为 '
                  'xlsx/docx/pptx/txt/md/csv/tsv 之一；ops）。'
                  'xlsx 用 set_cells/set_range/add_sheet/ensure_sheet；'
                  'docx 用 replace_text；pptx 用 set_shape_text；'
                  'txt/md/csv/tsv 用 replace_text 或 set_text（整文件覆写）。'
            : '用户上传了可编辑文件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv）。'
                  '若要求改文件内容/查找替换/回传，调用 edit_document。',
      );
    }
    if (useDocumentConvertTool && !forceDocTool) {
      hint.write('若要求格式转换（如 txt→docx、csv→xlsx、docx→md），调用 convert_document。');
    }
    if (useDocumentEditTool || useDocumentConvertTool) {
      hint.write('不要编造未上传的附件名。');
    }
    if (mcpPassthroughTools.isNotEmpty) {
      hint.write(
        '已连接 MCP Server，还可调用：'
        '${[for (final tool in mcpPassthroughTools) tool.name].join("、")}。',
      );
    }
    if (workMode) {
      hint.write(ToolLoopPolicy.workModeHint);
    }
    return hint.toString();
  }
}
