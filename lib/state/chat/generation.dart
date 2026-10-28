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
    ChatMessage? recoverySource,
    String priorExecutionEvidence = '',
    int? oneTimeWorkRounds,
    List<_SessionEvent> injectedEvents = const [],
  }) async {
    // The conversation was deleted while this turn was preflighting (awaiting
    // settings). Abandon the turn: re-inserting [working] here would resurrect
    // the deleted row both in memory and, via persistById, in the database.
    if (_deletedWhileStartingIds.contains(working.id)) return;
    if (!_requireLoadedConversation(working)) return;
    final contextSelection=ref.read(contextSelectionsProvider)[working.id]??const ContextSelection();
    final attachmentConversation=contextSelection.forTools(working);
    settings = await resolveDeepSeekSearchSettings(ref, settings);
    if (!working.isStoryLike && !working.isStudy) {
      config = await resolveConversationModel(
        ref,
        working.id,
        config,
        work: working.workMode,
        images: _userAttachmentsForTurn(
          attachmentConversation,
          assistantId,
        ).any((a) => a.isImage),
        thinking: thinking,
        choiceOverride: _run?.configuration?.modelChoice,
        useChoiceOverride: _zoneRun != null,
        settingsOverride: _run?.configuration?.settings,
        servicePrioritiesOverride: _run?.configuration?.servicePriorities,
      );
      if (!ref.mounted || _deletedWhileStartingIds.contains(working.id)) return;
    }
    final effectiveContext = effectiveContextPrefs(settings, config);
    settings = settings.copyWith(context: effectiveContext);
    config = applyContextConfig(config, effectiveContext).copyWith(
      reasoningGuardEnabled: !working.workMode,
      serverWebSearch: false,
      forceServerWebSearch: false,
    );
    final workTaskCore = working.workMode ? _run?.core : null;
    if (workTaskCore case final core?) {
      if (core.target.isEmpty) {
        try {
          core.target = await _taskTarget(working.id);
        } catch (error) {
          // A removed workspace or SSH profile ends this turn visibly; it must
          // not escape sendMessage or silently redirect to another target.
          if (!ref.mounted) return;
          _set(
            _s.copyWith(
              conversations: [
                working,
                ..._s.conversations.where((c) => c.id != working.id),
              ],
            ),
          );
          await _persistence.persistSafely(working.id);
          _setScopedError(describeError(error), convoId: working.id);
          return;
        }
      }
      final acceptance = ref.read(taskAcceptanceProvider.notifier);
      await acceptance.freeze(
        core.rootId,
        acceptance.draftCriteriaForConversation(working.id),
        conversationId: working.id,
        requireExisting:
            core.resumeRequired ||
            core.lineage.isNotEmpty ||
            core.agentTaskId != null,
      );
    }
    _run?.taskId = assistantId;
    if (_run case final agentRun?) {
      agentRun.agentTaskId ??= assistantId;
      if (agentRun.originatingUserGoal.isEmpty) {
        agentRun.originatingUserGoal = searchQuery;
      }
    }
    _run?.acceptedTaskIds.add(assistantId);
    if (_run case final run?) {
      _checkpointSession(run, SessionExecutionStatus.running, '模型与工作区已确定');
    }
    final sessionPolicy = _policyFor(working.id);
    final enableWorkspace =
        working.workMode &&
        !working.isStoryLike &&
        !working.isStudy &&
        recoverySource == null &&
        (sessionPolicy.sshProfileId.isNotEmpty ||
            ref.read(desktopWorkspaceHostProvider).supported);
    final selectedWorkspaceId = enableWorkspace
        ? _run?.configuration?.workspaceId
        : null;
    final searchMode = sessionPolicy.network ? _s.searchMode : SearchMode.off;
    final searchAllowed =
        recoverySource == null &&
        searchMode != SearchMode.off &&
        settings.searchConfigured &&
        searchQuery.trim().isNotEmpty &&
        !working.isStoryLike &&
        !working.isStudy;
    // Hosted web_search (DeepSeek Responses) when the user picked the provider
    // backend and the active model supports it. Otherwise the client tool /
    // pre-search path stays in charge.
    final useProviderSearch =
        searchAllowed &&
        settings.taskBudget.maxSearches > 0 &&
        settings.taskBudget.maxToolCalls > 0 &&
        settings.effectiveSearchBackend.isProviderHosted &&
        config.capabilities.supportsServerWebSearch;
    final useWebSearchTool =
        searchAllowed &&
        !useProviderSearch &&
        config.capabilities.supportsTools;
    // Work tasks may follow public documentation links under their network
    // permission. Ordinary chat keeps explicit user/search-source matching.
    final pastedUrls = recoverySource == null
        ? extractHttpUrls(searchQuery)
        : <String>[];
    // Browser clients cannot safely pin DNS and arbitrary pages are normally
    // CORS-blocked. Until a trusted fetch proxy exists, keep direct fetch off.
    final directPageFetchAllowed =
        !kIsWeb || settings.effectiveSearchBackend == SearchBackend.deepseek;
    final useFetchUrlTool =
        sessionPolicy.network &&
        directPageFetchAllowed &&
        settings.searchConfigured &&
        (working.workMode || pastedUrls.isNotEmpty || searchAllowed) &&
        config.capabilities.supportsTools;
    // Dialogue 配图 (not pure 生图 mode): auto exposes the tool; always also
    // pre-generates one image so force works on tool-less reasoners.
    final imageGenMode = _s.imageGenMode;
    final imageGenConfigured = settings.imageGenerationConfigured;
    final imageGenWanted =
        recoverySource == null &&
        imageGenMode != ImageGenMode.off &&
        imageGenConfigured &&
        !working.isStudy;
    // Document edit: Linux service + editable file with retained bytes + tools.
    final turnUserAttachments = _userAttachmentsForTurn(attachmentConversation, assistantId);
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
    final historyImages = VisionTools.attachmentsFor(attachmentConversation);
    final visionSources = [
      ...turnImages,
      for (final a in historyImages)
        if (!turnImages.any((t) => t.id == a.id)) a,
    ];
    final nativeVision =
        config.capabilities.supportsVision && visionSources.isNotEmpty;
    final visionToolWanted =
        recoverySource == null &&
        !nativeVision &&
        settings.visionConfigured &&
        visionSources.isNotEmpty;
    final useVisionTool =
        visionToolWanted && config.capabilities.supportsTools && !forceDocTool;
    final needPreVision =
        visionToolWanted && !useVisionTool && turnImages.isNotEmpty;
    final toolSpecs = <ToolSpec>[
      if (working.workMode &&
          recoverySource == null &&
          config.capabilities.supportsTools)
        workQuestionTool,
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
        settings.effectiveSearchBackend.isProviderHosted &&
        !config.capabilities.supportsServerWebSearch) {
      // Soft notice once per turn: official search only works on flash today.
      _setScopedError(
        '当前模型不支持提供商官方联网（需 DeepSeek V4），'
        '本轮将回退到客户端搜索后端。',
        convoId: working.id,
      );
    }
    final allowedFetchUrls = {
      for (final url in pastedUrls) SearchToolExecutor.fetchUrlKey(url),
    };
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
    _execution.attachRequest(cancelToken);
    _beginTaskBudget(settings);

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
    // Write the user turn and assistant placeholder before any network work.
    // If the app is backgrounded or killed during a long response, the turn is
    // still recoverable on the next launch.
    try {
      await _persistence.persistById(working.id);
      if (_run != null && injectedEvents.isNotEmpty) {
        await _ackSessionEvents(_run!, injectedEvents);
      }
    } catch (e) {
      // Don't crash the send action on a transient local-storage failure. The
      // final/checkpoint writes will retry through the serialized queue, while
      // the user gets a visible diagnostic instead of losing the live reply.
      _setScopedError('本地保存失败：$e', convoId: working.id);
      if (injectedEvents.isNotEmpty) {
        _run?.core?.resumeRequired = true;
        rethrow;
      }
    }

    // Freeze memory before search/tool awaits, using the originating project.
    var memoryPrompt = '';
    if (settings.memoryEnabled) {
      try {
        final recall = await ref
            .read(memoryRepositoryProvider)
            .recall(
              searchQuery,
              projectId: working.projectId,
              maxItems: 8,
              maxChars: 4000,
            );
        memoryPrompt = recall.toSystemPrompt();
      } catch (_) {
        // Optional local memory must not block an otherwise usable chat.
      }
    }
    var projectPrompt = '';
    if (working.projectId != null && recoverySource == null) {
      final started = DateTime.now();
      try {
        final project = await ref
            .read(projectRepositoryProvider)
            .context(working.projectId!);
        projectPrompt = project.prompt;
        _upsertSearchActivity(
          working.id,
          assistantId,
          SearchActivity(
            kind: SearchActivityKind.document,
            query: '项目资料：${project.name}',
            status: SearchActivityStatus.done,
            startedAt: started,
            finishedAt: DateTime.now(),
            items: [
              for (final name in project.sources)
                SearchActivityItem(title: name),
            ],
            resultText:
                '以下为项目资料载入快照，后续仍受上下文预算裁剪；不代表全部内容已发送。\n\n${project.prompt}',
            resultCount: project.sources.length,
          ),
        );
      } catch (e) {
        // Fail closed: don't silently answer without the user's project context.
        _setScopedError('项目资料读取失败：$e', convoId: working.id);
        _set(_s.copyWith(streamingConvoId: null));
        await _persistence.persistSafely(working.id);
        _execution.releaseRequest(cancelToken);
        _execution.endBudget();
        unawaited(
          GenerationNotify.onGenerationEnd(
            sessionId: _run?.conversationId,
            success: false,
            conversationTitle: working.title,
          ),
        );
        return;
      }
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
    final enableTools = recoverySource == null && toolSpecs.isNotEmpty;
    // Tool-capable models can decide when the pasted link is relevant. Models
    // without function calling keep the deterministic pre-fetch fallback.
    final needPreFetch =
        settings.searchConfigured &&
        directPageFetchAllowed &&
        pastedUrls.isNotEmpty &&
        !useFetchUrlTool;
    // Provider-hosted search is done inside the Responses stream. Tool-capable
    // models call web_search themselves; 联网·强制 becomes tool_choice.
    final needPreSearch =
        searchAllowed && !useProviderSearch && !useWebSearchTool;
    // Client search and retries use DeepSeek Search / Fetch by default.
    final clientSearchBackend =
        settings.effectiveSearchBackend.isProviderHosted && !useProviderSearch
        ? SearchBackend.deepseek
        : settings.effectiveSearchBackend;
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
          apiKey: settings.effectiveSearchApiKey,
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
      _execution.releaseRequest(cancelToken);
      // stop() already ends the notify session when the user pressed stop;
      // still clear wakelock if streaming dropped for another reason.
      unawaited(
        GenerationNotify.onGenerationEnd(
          sessionId: _run?.conversationId,
          success: false,
          conversationTitle: working.title,
          cancelled: _execution.isCancelled,
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
      _execution.releaseRequest(cancelToken);
      return;
    }

    // Load turn-specific data here; the builder receives only completed snapshots.
    var storyContext = const StoryRequestContext();
    ChatSkillRoute? skillRoute;
    var studySystem = '';
    if (cur.isStoryLike) {
      final worldPool = cur.worldInfoIds.isEmpty
          ? const <WorldInfoEntry>[]
          : await ref
                .read(worldInfoRepositoryProvider)
                .loadByIds(cur.worldInfoIds);
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

      storyContext = StoryRequestContext(
        character: card,
        cast: cast,
        speakingAs: ensembleSpeaker,
        worldInfo: worldPool,
        advancePlot: advancePlot,
        promptPlotCursor: promptPlotCursor,
        intent: storyIntent,
      );
    } else {
      if (recoverySource == null &&
          !cur.workMode &&
          cur.mode == ConversationMode.chat &&
          settings.chatSkills.enabled.isNotEmpty) {
        if (!settings.config.isReady) {
          skillRoute = ChatSkillRoute(
            skill: settings.chatSkills.fallback,
            source: ChatSkillSource.fallback,
          );
        } else {
          final parentUser = _parentUserForTurn(working, assistantId);
          skillRoute = await const ChatSkillRouter().route(
            jevConfig: settings.jevConfig,
            jevApiKey: settings.jevApiKey,
            jevClient: ref.read(jevClientProvider),
            userText: parentUser?.content ?? '',
            recent: _recentTurnsBefore(
              attachmentConversation,
              assistantId: assistantId,
              excludeId: parentUser?.id,
            ),
            catalog: settings.chatSkills,
            llm: ref.read(llmProvider),
            config: settings.config.copyWith(
              model: settings.active?.chatModel ?? settings.model,
              reasoningGuardEnabled: !working.workMode,
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
      if (cur.isStudy) studySystem = await _studySystemPrompt(cur);
    }

    if (!_s.isStreaming) {
      await _persistence.persistSafely(working.id);
      // Drop our token like _streamAnswer's finally would.
      _execution.releaseRequest(cancelToken);
      return;
    }

    final toolHint = enableTools
        ? ClientToolPrompt.build(
            dateLine: ToolEngine.dateLine(),
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
          )
        : '';
    final contextResult =
        RequestContextBuilder(
          contextWindow: ref.read(contextWindowManagerProvider),
        ).prepare(
          conversation: cur,
          assistantId: assistantId,
          contextPrefs: settings.context,
          selection: contextSelection,
          nativeVision: nativeVision,
          imageToolAvailable: useVisionTool,
          chatRoute: skillRoute,
          fallbackPrompt: settings.systemPrompt,
          studySystemPrompt: studySystem,
          story: storyContext,
          notes: RequestContextNotes(
            project: projectPrompt,
            memory: memoryPrompt,
            search: searchContext?.contextText ?? '',
            image: forceImageNote,
            vision: preVisionNote,
            tools: toolHint,
            recovery: recoverySource == null
                ? priorExecutionEvidence
                : RequestContextBuilder.savedResultsPrompt(recoverySource),
          ),
        );
    if (contextResult.worldInfoHits.isNotEmpty) {
      _setAppliedWorldInfo(
        working.id,
        assistantId,
        contextResult.worldInfoHits,
      );
    }
    _recordContextReport(working.id, contextResult.report);
    if (contextResult.exceedsBudget) {
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
      _execution.releaseRequest(cancelToken);
      unawaited(
        GenerationNotify.onGenerationEnd(
          sessionId: _run?.conversationId,
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
    if (recoverySource != null) {
      _execution.budget?.requestFinish('用户选择使用已有资料回答');
    }
    final turnEffort = LlmRequestPolicy.selectEffort(
      config: config,
      savedEffort: _run?.configuration?.effort ?? _s.reasoningEffort,
      hasSavedOverride: settings.hasReasoningEffortOverride,
      proseTask: contextResult.proseTask,
      workMode: working.workMode,
      manualEffort: _editedComposerPrefs.contains('effort')
          ? _s.reasoningEffort
          : null,
    );
    if (thinking && _s.currentId == working.id) {
      _set(_s.copyWith(reasoningEffort: turnEffort));
    }
    final succeeded = await _streamAnswer(
      config: streamConfig,
      history: contextResult.messages,
      convoId: working.id,
      assistantId: assistantId,
      thinking: thinking,
      reasoningEffort: turnEffort,
      settings: settings,
      fallbackSearchQuery: searchQuery,
      enableTools: enableTools || useProviderSearch,
      toolSpecs: toolSpecs,
      initialCitations:
          recoverySource?.citations ??
          searchContext?.citations ??
          const <Citation>[],
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
      enableWorkspace: enableWorkspace,
      selectedWorkspaceId: selectedWorkspaceId,
      oneTimeWorkRounds: oneTimeWorkRounds,
    );

    if (ref.mounted && succeeded && working.workMode && _run?.core != null) {
      await ref.read(taskAcceptanceProvider.notifier).update(
        _run!.core!.rootId,
        (task) {
          task.replyComplete = true;
          task.toolsComplete = !_hasPendingSessionWork(_run!);
        },
      );
    }
    unawaited(
      GenerationNotify.onGenerationEnd(
        sessionId: _run?.conversationId,
        success: succeeded,
        conversationTitle: working.title,
        preview: ref.mounted ? _previewFor(working.id, assistantId) : null,
        cancelled: !succeeded && _execution.isCancelled,
      ),
    );

    // A successful "write next scene" action advances exactly one beat.
    // Length is pacing guidance only; it must never keep a dramatically
    // complete scene open just to satisfy an estimated character quota.
    if (ref.mounted && succeeded && commitPlotAdvance && cur.isStory) {
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
}
