part of '../chat_controller.dart';

mixin ChatTurns on ChatMedia {
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
        isProcessingDocument: false,
      ),
    );
    _signalIdleIfReady();
    if (persist && streamingId != null) {
      _persistence.persistSoon(_persistence.persistById(streamingId));
    }
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

  /// Send a new user turn at the end of the active branch. Returns false when
  /// the send was rejected up front (empty input, already streaming, settings
  /// not ready) so the UI can restore the user's draft.
  Future<bool> sendMessage(
    String text, {
    List<Attachment> attachments = const [],

    /// When true, force the model to call [edit_document] (manual「改文档」).
    bool forceDocumentEdit = false,
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && attachments.isEmpty) ||
        _s.isStreaming ||
        _starting) {
      return false;
    }
    if (forceDocumentEdit) {
      final hasDoc = attachments.any((a) => a.isEditableDocument);
      if (!hasDoc) return false;
    }
    _starting = true;
    _cancelStart = false;
    try {
      final convo = _s.current ?? Conversation();
      final requiresVision = attachments.any(
        (a) => a.isImage && a.hasImageData,
      );
      final settings = await _readySettingsForTurn(
        requireVision: requiresVision,
      );
      if (settings == null || _cancelStart) return false;
      if (forceDocumentEdit && !settings.supportsDocumentEdit) {
        _set(_s.copyWith(error: '请先在设置中连接并发现支持文档编辑的 MCP Tools。'));
        return false;
      }
      final config = _configForTurn(settings, hasImages: requiresVision);
      if (forceDocumentEdit && !config.capabilities.supportsTools) {
        _set(
          _s.copyWith(
            error: '当前模型不支持工具调用，无法强制改文档。请换用支持 function calling 的对话模型。',
          ),
        );
        return false;
      }

      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      final userContent = forceDocumentEdit && trimmed.isEmpty
          ? '请根据本轮附件，调用 edit_document 修改文件并回传。'
          : (forceDocumentEdit
                ? '$trimmed\n\n【系统】请务必调用 edit_document 完成本次文件修改并回传。'
                : trimmed);
      final userMsg = ChatMessage(
        role: MessageRole.user,
        content: userContent,
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
        title: isFirst ? truncateTitle(titleSeed) : convo.title,
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: activeChildrenAfterAppending(
          convo.activeChildren,
          const [],
          parentId: parentId,
          childId: userMsg.id,
          grandchildId: assistantMsg.id,
        ),
      );

      if (_cancelStart) return false;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: settings,
        searchQuery: userContent,
        thinking: _s.deepThink,
        storyIntent: convo.isStory && convo.localCast.isNotEmpty
            ? StoryGenerationIntentResolver.fromUserText(userContent)
            : null,
        forceDocumentEdit: forceDocumentEdit,
      );
      return true;
    } finally {
      _finishStarting();
    }
  }

  /// Starts a durable Gateway document job instead of an ordinary SSE
  /// chat turn. The assistant placeholder is persisted before upload begins;
  /// once the provider returns a response id, closing this app no longer stops
  /// the remote work and the id is polled again on the next launch.
  Future<bool> sendLongDocumentTask(
    String text, {
    required List<Attachment> attachments,
  }) async {
    final documents = [
      for (final a in attachments)
        if (!a.isImage) a,
    ];
    if (documents.isEmpty || _s.isStreaming || _starting) return false;
    if (documents.any((a) => !a.hasDownloadableBytes)) {
      _setScopedError('长任务需要上传原始文件；请移除旧附件并重新选择文件。');
      return false;
    }

    _starting = true;
    _cancelStart = false;
    try {
      final settings = await _readySettings();
      if (settings == null || _cancelStart) return false;
      if (!settings.supportsLongTasks) {
        _setScopedError('当前 MCP Server 未提供文件长任务；该能力仅在旧 Gateway 部署中可用。');
        return false;
      }
      final gateway = settings.gateway;
      final gatewayModel = gateway.taskModel.trim();
      final prompt = text.trim().isEmpty
          ? '请完整阅读并深入分析上传文件，提炼关键信息、依据、风险和可执行结论。'
          : text.trim();
      final convo = _s.current ?? Conversation();
      final parentId = convo.activePath.isEmpty
          ? null
          : convo.activePath.last.id;
      final userMsg = ChatMessage(
        role: MessageRole.user,
        content: prompt,
        attachments: documents,
        parentId: parentId,
      );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: gatewayModel.isEmpty ? 'Gateway 默认模型' : gatewayModel,
        parentId: userMsg.id,
        longTask: LongTaskState(
          status: LongTaskStatus.preparing,
          providerProfileId: '',
          providerName: 'Expert Chat Gateway',
          baseUrl: gateway.baseUrl.trim(),
          uploadBaseUrl: gateway.uploadBaseUrl.trim(),
          model: gatewayModel,
          detail: '正在准备文件',
        ),
      );
      final isFirst = convo.messages.isEmpty;
      final working = convo.copyWith(
        title: isFirst ? truncateTitle(prompt) : convo.title,
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: activeChildrenAfterAppending(
          convo.activeChildren,
          const [],
          parentId: parentId,
          childId: userMsg.id,
          grandchildId: assistantMsg.id,
        ),
      );
      final holdsFocus = _s.currentId == working.id || _s.currentId == null;
      _set(
        _s.copyWith(
          conversations: [
            working,
            ..._s.conversations.where((c) => c.id != working.id),
          ],
          currentId: holdsFocus ? working.id : _s.currentId,
          error: null,
        ),
      );
      try {
        await _persistence.persistById(working.id);
      } catch (e) {
        _setScopedError('本地保存失败：$e', convoId: working.id);
      }
      unawaited(_longTasks.run(working.id, assistantMsg.id));
      return true;
    } finally {
      _finishStarting();
    }
  }

  @override
  Future<void> _resumeLongTasks() async {
    if (!ref.mounted) return;
    for (final conversation in _s.conversations) {
      if (!conversation.messagesLoaded) continue;
      for (final message in conversation.messages) {
        if (message.longTask?.isActive != true) continue;
        unawaited(_longTasks.run(conversation.id, message.id));
      }
    }
  }

  @override
  LongTaskState? _findLongTask(String convoId, String assistantId) {
    for (final convo in _s.conversations) {
      if (convo.id != convoId) continue;
      for (final message in convo.messages) {
        if (message.id == assistantId) return message.longTask;
      }
    }
    return null;
  }

  @override
  Future<void> _writeLongTask(
    String convoId,
    String assistantId,
    LongTaskState task, {
    String? content,
  }) async {
    final index = _s.conversations.indexWhere((c) => c.id == convoId);
    if (index < 0) return;
    final convo = _s.conversations[index];
    final messages = [
      for (final message in convo.messages)
        if (message.id == assistantId)
          message.copyWith(content: content ?? message.content, longTask: task)
        else
          message,
    ];
    _set(
      _s.copyWith(conversations: _replace(convo.copyWith(messages: messages))),
    );
    await _persistence.persistSafely(convoId);
  }

  Future<void> cancelLongTask(String convoId, String assistantId) =>
      _longTasks.cancel(convoId, assistantId);

  Future<void> retryLongTask(String convoId, String assistantId) =>
      _longTasks.retry(convoId, assistantId);

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
      final hasImages = nextAttachments.any((a) => a.isImage && a.hasImageData);
      final turnSettings = await _readySettingsForTurn(
        requireVision: hasImages,
      );
      if (turnSettings == null || _cancelStart) return;
      final config = _configForTurn(turnSettings, hasImages: hasImages);

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
      final pathToParent = pathToOptionalMessage(convo, old.parentId);
      final working = convo.copyWith(
        messages: [...convo.messages, userMsg, assistantMsg],
        activeChildren: activeChildrenAfterAppending(
          convo.activeChildren,
          pathToParent,
          parentId: old.parentId,
          childId: userMsg.id,
          grandchildId: assistantMsg.id,
        ),
      );

      if (_cancelStart) return;

      await _generate(
        working: working,
        assistantId: assistantMsg.id,
        config: config,
        settings: turnSettings,
        searchQuery: trimmed,
        thinking: _s.deepThink,
        storyIntent: convo.isStory && convo.localCast.isNotEmpty
            ? StoryGenerationIntentResolver.fromUserText(trimmed)
            : null,
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
      final path = pathToMessage(convo, parentId);
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
    final advanceCue = ChatSessions.isPlotAdvanceUserContent(userMsg.content);
    final storyIntent =
        retryOperation?.storyIntent ??
        (convo.isStory && convo.localCast.isNotEmpty
            ? StoryGenerationIntentResolver.fromUserText(userMsg.content)
            : null);
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
      final hasImages = userMsg.attachments.any(
        (a) => a.isImage && a.hasImageData,
      );
      final settings = await _readySettingsForTurn(requireVision: hasImages);
      if (settings == null || _cancelStart) return;
      final config = _configForTurn(settings, hasImages: hasImages);

      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: config.model,
        parentId: userMsg.id,
      );
      final working = convo.copyWith(
        messages: [...convo.messages, assistantMsg],
        activeChildren: activeChildrenAfterAppending(
          convo.activeChildren,
          pathToUser,
          parentId: userMsg.id,
          childId: assistantMsg.id,
        ),
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
        storyIntent: storyIntent,
      );
    } finally {
      _finishStarting();
    }
  }

  /// Switch which sibling branch is active at [messageId] (delta -1 / +1).
  void switchBranch(String messageId, int delta) {
    // The _starting guard matches every other mutating entry point: a switch
    // during the preflight window would be silently rolled back by _generate
    // installing its own snapshot of activeChildren.
    if (_s.isStreaming || _starting) return;
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

    _persistence.persistSoon(_persistence.persist());
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
      final pathToParent = pathToOptionalMessage(convo, parentId);
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
        activeChildren: activeChildrenAfterAppending(
          convo.activeChildren,
          pathToParent,
          parentId: parentId,
          childId: assistantMsg.id,
        ),
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
}
