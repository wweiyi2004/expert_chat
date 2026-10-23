part of '../chat_controller.dart';

/// Recovery is an explicit user action, never an automatic replay of side effects.
mixin ChatTaskRecovery on ChatSessions {
  void requestTaskAnswer(String convoId, String msgId) => _withSession(() {
    if (_s.streamingConvoId != convoId || _execution.isCancelled) return;
    final last = _s.conversations
        .where((c) => c.id == convoId)
        .firstOrNull
        ?.activePath
        .lastOrNull;
    if (last?.id != msgId || last?.kind == MessageKind.generatedImage) return;
    _execution.budget?.requestFinish('用户选择使用已有资料回答');
  }, conversationId: convoId);

  Future<void> answerFromResults(String convoId, String msgId) =>
      _inSession(() async {
        if (_s.isStreaming) {
          requestTaskAnswer(convoId, msgId);
          return;
        }
        if (_execution.isActive || _s.currentId != convoId) return;
        final convo = _s.current;
        final source = _messageById(convoId, msgId);
        if (convo == null ||
            source == null ||
            source.role != MessageRole.assistant ||
            source.kind == MessageKind.generatedImage ||
            convo.isStoryLike ||
            convo.isStudy) {
          return;
        }
        final user = _parentUserForTurn(convo, msgId);
        if (user == null) return;
        if (!_tryStartGeneration()) return;
        try {
          final settings = await _readySettingsForTurn();
          if (settings == null || _execution.isCancelled) return;
          final answer = ChatMessage(
            role: MessageRole.assistant,
            content: '',
            model: settings.model,
            parentId: user.id,
            citations: source.citations,
            searchActivities: source.searchActivities,
            attachments: source.attachments,
          );
          final working = convo.copyWith(
            messages: [...convo.messages, answer],
            activeChildren: activeChildrenAfterAppending(
              convo.activeChildren,
              pathToMessage(convo, user.id),
              parentId: user.id,
              childId: answer.id,
            ),
          );
          await _generate(
            working: working,
            assistantId: answer.id,
            config: settings.config.copyWith(allowReasoningRetry: false),
            settings: settings,
            searchQuery: user.content,
            thinking: false,
            recoverySource: source,
          );
        } finally {
          _finishStarting();
        }
      }, conversationId: convoId);

  Future<void> retryTaskStep(
    String convoId,
    String msgId,
    String stepId, {
    bool confirmedPaidRequest = false,
  }) => _inSession(() async {
    if (_s.isStreaming || _execution.isActive || _s.currentId != convoId) {
      return;
    }
    final convo = _s.current;
    final source = _messageById(convoId, msgId);
    final step = source?.searchActivities
        .where((a) => a.id == stepId)
        .firstOrNull;
    if (convo == null || source == null || step == null || !step.canRetry) {
      return;
    }
    if (source.searchActivities.any(
      (a) => a.retryOfId == stepId && a.status == SearchActivityStatus.done,
    )) {
      return;
    }
    if (step.retryNeedsConfirmation && !confirmedPaidRequest) return;
    final user = _parentUserForTurn(convo, msgId);
    if (user == null) return;
    if (source.kind == MessageKind.generatedImage &&
        step.toolName == 'generate_image') {
      final args = DialogueImageExecutor.parseToolArgs(step.toolArguments!);
      if (args.prompt == null) return;
      await _generateImageTurn(
        user.content,
        referenceImages: user.attachments,
        existingUserMessageId: user.id,
        preparedPrompt: args.prompt,
      );
      return;
    }
    if (!_tryStartGeneration()) return;
    final token = CancelToken();
    _execution.attachRequest(token);
    var targetMsgId = msgId;
    try {
      final settings = await _settingsForSession();
      if (_execution.isCancelled) return;
      final isSearch = step.toolName == 'web_search';
      if ((isSearch && _s.searchMode == SearchMode.off) ||
          (step.toolName == 'generate_image' &&
              _s.imageGenMode == ImageGenMode.off)) {
        _setScopedError('当前已关闭该能力，请先启用后再重试。', convoId: convoId);
        return;
      }
      // Retrying a built-in step must not turn off restrictions from the
      // original turn, including the fetch URL allow-list and one-image cap.
      if (step.toolName == 'generate_image' &&
          source.attachments.any((a) => a.isImage)) {
        _setScopedError('本轮已有图片，不重复提交生图。', convoId: convoId);
        return;
      }
      _beginTaskBudget(settings);
      final latestConvo = _s.conversations
          .where((c) => c.id == convoId)
          .firstOrNull;
      if (latestConvo == null || _deletedWhileStartingIds.contains(convoId)) {
        return;
      }
      final retry = ChatMessage(
        role: MessageRole.assistant,
        content: '正在重试步骤…',
        parentId: user.id,
        model: source.model,
        attachments: source.attachments,
        citations: source.citations,
        searchActivities: source.searchActivities,
      );
      targetMsgId = retry.id;
      final working = latestConvo.copyWith(
        messages: [...latestConvo.messages, retry],
        activeChildren: activeChildrenAfterAppending(
          latestConvo.activeChildren,
          pathToMessage(latestConvo, user.id),
          parentId: user.id,
          childId: retry.id,
        ),
      );
      _set(
        _s.copyWith(
          conversations: _replace(working),
          streamingConvoId: convoId,
          error: null,
        ),
      );
      await _persistence.persistSafely(convoId);
      final before = source.searchActivities.map((a) => a.id).toSet();
      await _executeToolCalls(
        toolCalls: [
          ToolCall(
            index: 0,
            id: 'retry_$stepId',
            name: step.toolName,
            argumentsJson: step.toolArguments!,
          ),
        ],
        settings: settings,
        fallbackSearchQuery: user.content,
        convoId: convoId,
        assistantId: targetMsgId,
        citations: List.of(source.citations),
        allowedFetchUrls: extractHttpUrls(
          user.content,
        ).map(SearchToolExecutor.fetchUrlKey).toSet(),
        cancelToken: token,
        imageBudget: _TurnImageBudget(),
        imageCharacter: await _resolveImageCharacter(convo),
        clientSearchBackend: settings.effectiveSearchBackend.isProviderHosted
            ? SearchBackend.deepseek
            : settings.effectiveSearchBackend,
        editableAttachments: user.attachments,
      );
      final latest = _messageById(convoId, targetMsgId);
      for (final activity in latest?.searchActivities ?? <SearchActivity>[]) {
        if (!before.contains(activity.id)) {
          _upsertSearchActivity(
            convoId,
            targetMsgId,
            activity.copyWith(retryOfId: step.id),
          );
        }
      }
      final completed =
          latest?.searchActivities
              .where((a) => !before.contains(a.id))
              .any((a) => a.status == SearchActivityStatus.done) ??
          false;
      _updateAssistant(
        convoId,
        targetMsgId,
        completed ? '步骤已完成，可使用已有资料重新整理答复。' : '步骤未完成，请查看执行记录。',
        '',
        0,
      );
    } catch (e) {
      if (!isCancelError(e)) {
        _setScopedError(describeError(e), convoId: convoId);
      }
    } finally {
      _endPendingActivities(convoId, targetMsgId, '已停止本地等待；远端状态未确认');
      if ((_execution.budget?.finishing ?? false) && !_execution.isCancelled) {
        _setScopedError(
          '${_execution.budget!.reason}；已停止本地等待，远端状态未确认。',
          convoId: convoId,
        );
      }
      if (_s.streamingConvoId == convoId) {
        _set(
          _s.copyWith(
            streamingConvoId: null,
            isSearching: false,
            isGeneratingImage: false,
            isProcessingDocument: false,
          ),
        );
      }
      _execution.releaseRequest(token);
      await _persistence.persistSafely(convoId);
      _finishStarting();
    }
  }, conversationId: convoId);
}
