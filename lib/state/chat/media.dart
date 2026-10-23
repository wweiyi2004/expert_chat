part of '../chat_controller.dart';

mixin ChatMedia on ChatGeneration {
  /// Generate an image as a normal conversation turn. This endpoint is wholly
  /// optional and does not depend on the main chat provider being configured
  /// — unless [ChatState.deepThink] is on, in which case the chat/reasoner
  /// model first rewrites the prompt, then the result is sent to the image API.
  ///
  /// When [referenceImages] contains an image with data, the request uses the
  /// OpenAI-compatible `/images/edits` (图生图) path; otherwise text-to-image.
  Future<bool> generateImage(
    String prompt, {
    List<Attachment> referenceImages = const [],
  }) => _generateImageTurn(prompt, referenceImages: referenceImages);

  /// UI must obtain confirmation for a new paid image request first.
  Future<bool> regenerateImageVersion(GenerationRecord record) =>
      _generateImageTurn(
        record.originalPrompt,
        preparedPrompt: record.optimizedPrompt,
        version: record,
      );

  Future<bool> _generateImageTurn(
    String prompt, {
    List<Attachment> referenceImages = const [],
    String? existingUserMessageId,
    String? preparedPrompt,
    GenerationRecord? version,
  }) => _inSession(() async {
    final trimmed = prompt.trim();
    var refs = [
      for (final a in referenceImages)
        if (a.isImage && a.hasImageData) a,
    ];
    if (trimmed.isEmpty || _s.isStreaming || _execution.isActive) return false;
    if (!_tryStartGeneration()) return false;
    // Capture the originating conversation before the settings preflight: the
    // user may switch conversations while settings load, and the turn must
    // still target the conversation it started from (matching _generate).
    final originConvo = _s.current;
    try {
      if (originConvo != null && !_requireLoadedConversation(originConvo)) {
        return false;
      }
      var settings = await _settingsForSession();
      if (version != null) {
        if (GenerationRepository.providerOrigin(
              settings.imageGenerationApi.baseUrl,
            ) !=
            version.providerHost) {
          throw StateError('当前生图服务与原记录不同。请先配置原服务，再按原参数生成。');
        }
        settings = settings.copyWith(
          imageGenerationApi: settings.imageGenerationApi.copyWith(
            model: version.model,
            imageSize: version.imageSize,
            apiFormat: version.apiFormat == null
                ? null
                : LlmApiFormat.values.byName(version.apiFormat!),
          ),
        );
        refs = await ref.read(generationRepositoryProvider).references(version);
        if (refs.length > settings.imageGenerationApi.maxImageEditReferences) {
          throw StateError('当前接口无法接收原记录的全部参考图。');
        }
      }
      if (!settings.imageGenerationConfigured) {
        _set(_s.copyWith(error: '请先在设置中完整配置图片生成 API。'));
        return false;
      }
      final useDeepThink = preparedPrompt == null && _s.deepThink;
      if (useDeepThink && !settings.config.isReady) {
        _set(_s.copyWith(error: '深度思考生图需要先配置对话 API（用于优化提示词）。'));
        return false;
      }
      if (_execution.isCancelled) return false;

      final maxRefs = settings.imageGenerationApi.maxImageEditReferences;
      final usedRefs = refs.length > maxRefs ? refs.sublist(0, maxRefs) : refs;

      final convo = originConvo ?? _s.current ?? Conversation();
      ChatMessage? existingUser;
      if (existingUserMessageId != null) {
        for (final message in convo.messages) {
          if (message.id == existingUserMessageId &&
              message.role == MessageRole.user) {
            existingUser = message;
            break;
          }
        }
        if (existingUser == null) return false;
      }
      final parentId =
          existingUser?.parentId ??
          (convo.activePath.isEmpty ? null : convo.activePath.last.id);
      final userMsg =
          existingUser ??
          ChatMessage(
            role: MessageRole.user,
            content: trimmed,
            parentId: parentId,
            attachments: usedRefs,
          );
      final assistantMsg = ChatMessage(
        role: MessageRole.assistant,
        content: '',
        model: useDeepThink
            ? _configFor(settings).model
            : settings.imageGenerationApi.model,
        kind: MessageKind.generatedImage,
        parentId: userMsg.id,
      );
      final isFirst = existingUser == null && convo.messages.isEmpty;
      final pathToUser = pathToOptionalMessage(convo, existingUser?.id);
      final working = convo.copyWith(
        title: isFirst ? truncateTitle(trimmed) : convo.title,
        messages: [
          ...convo.messages,
          if (existingUser == null) userMsg,
          assistantMsg,
        ],
        activeChildren: activeChildrenAfterAppending(
          convo.activeChildren,
          pathToUser,
          parentId: existingUser == null ? parentId : userMsg.id,
          childId: existingUser == null ? userMsg.id : assistantMsg.id,
          grandchildId: existingUser == null ? assistantMsg.id : null,
        ),
      );
      final failureOperation = ChatRetryOperation(
        kind: ChatRetryKind.image,
        conversationId: working.id,
        assistantMessageId: assistantMsg.id,
      );
      final cancelToken = CancelToken();
      _execution.attachRequest(cancelToken);
      _beginTaskBudget(settings);
      // The user may have switched conversations while this turn was
      // preflighting; don't yank focus back. The image turn itself still
      // targets [working.id] and writes into it.
      final holdsFocus = _s.currentId == working.id || _s.currentId == null;
      _set(
        _s.copyWith(
          conversations: [
            working,
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
      try {
        await _persistence.persistById(working.id);
      } catch (e) {
        // Same contract as _generate: a transient local-storage failure must
        // not abort the turn (and must never strand streamingConvoId); the
        // final/checkpoint writes below retry through the serialized queue.
        _setScopedError('本地保存失败：$e', convoId: working.id);
      }

      SearchActivity? imageStep;
      void startStep(String query, {String? prompt}) {
        imageStep = SearchActivity(
          kind: SearchActivityKind.image,
          query: query,
          toolName: prompt == null ? null : 'generate_image',
          toolArguments: prompt == null ? null : jsonEncode({'prompt': prompt}),
        );
        _upsertSearchActivity(working.id, assistantMsg.id, imageStep!);
      }

      void finishStep({String? error, int resultCount = 0}) {
        final step = imageStep;
        if (step == null) return;
        _upsertSearchActivity(
          working.id,
          assistantMsg.id,
          step.copyWith(
            status: error == null
                ? SearchActivityStatus.done
                : SearchActivityStatus.failed,
            error: error,
            resultCount: resultCount,
          ),
        );
        imageStep = null;
      }

      try {
        var imagePrompt = preparedPrompt ?? trimmed;
        var optimizedByModel = '';
        var reasoning = '';
        var thinkingMillis = 0;

        if (useDeepThink) {
          startStep('优化提示词');
          var refined = '';
          try {
            refined = await _optimizeImagePrompt(
              userPrompt: trimmed,
              settings: settings,
              cancelToken: cancelToken,
              onReasoning: (text, millis) {
                reasoning = text;
                thinkingMillis = millis;
                _updateAssistant(
                  working.id,
                  assistantMsg.id,
                  '',
                  reasoning,
                  thinkingMillis,
                );
              },
            );
            finishStep(error: cancelToken.isCancelled ? '已取消' : null);
          } catch (e) {
            if (isCancelError(e) || cancelToken.isCancelled) rethrow;
            finishStep(error: '提示词优化未完成，使用原始描述');
          }
          if (!_s.isStreaming || cancelToken.isCancelled) {
            await _persistence.persistById(working.id);
            unawaited(
              GenerationNotify.onGenerationEnd(
                sessionId: _run?.conversationId,
                success: false,
                conversationTitle: working.title,
                cancelled: true,
              ),
            );
            return true;
          }
          optimizedByModel = refined;
          if (refined.isNotEmpty) imagePrompt = refined;
          _updateAssistant(
            working.id,
            assistantMsg.id,
            '正在生成图片…',
            reasoning,
            thinkingMillis,
          );
        }

        // Align pure 生图 with dialogue illustration: scrub NSFW phrasing and
        // append an SFW suffix before hitting the media API.
        imagePrompt = ImagePromptSafety.freeform(imagePrompt);

        if (usedRefs.isNotEmpty) startStep('准备参考图');
        final referencePreparation = await const ImageReferencePreparer()
            .prepare(
              usedRefs,
              preserveOriginalBytes: version != null,
              isActive: () => _s.isStreaming && !cancelToken.isCancelled,
            );
        if (referencePreparation.error != null) {
          _setScopedError(
            referencePreparation.error!,
            convoId: working.id,
            retryOperation: failureOperation,
          );
          _set(_s.copyWith(streamingConvoId: null));
          await _persistence.persistById(working.id);
          unawaited(
            GenerationNotify.onGenerationEnd(
              sessionId: _run?.conversationId,
              success: false,
              conversationTitle: working.title,
            ),
          );
          return true;
        }
        if (referencePreparation.cancelled) return true;
        final preparedRefs = referencePreparation.references;

        finishStep();
        if (cancelToken.isCancelled || !_s.isStreaming) return true;
        startStep('生成图片', prompt: imagePrompt);
        if (_s.isStreaming) {
          _set(
            _s.copyWith(
              isGeneratingImage: true,
              isSearching: false,
              isProcessingDocument: false,
            ),
          );
        }
        if (!(_execution.budget?.takeTool() ?? true)) {
          throw StateError(_execution.budget?.reason ?? '工具预算已用完');
        }
        final generated =
            await ImageGenerationService(
              getProvider: () => ref.read(mediaApiProvider),
            ).generate(
              config: settings.imageGenerationApi,
              apiKey: settings.imageGenerationApiKey,
              prompt: imagePrompt,
              cancelToken: cancelToken,
              references: preparedRefs,
            );
        if (!_s.isStreaming || cancelToken.isCancelled) {
          await _persistence.persistById(working.id);
          unawaited(
            GenerationNotify.onGenerationEnd(
              sessionId: _run?.conversationId,
              success: false,
              conversationTitle: working.title,
              cancelled: true,
            ),
          );
          return true;
        }
        final attachment = generated.attachment;
        final content = ImageGenerationService.resultContent(
          originalPrompt: trimmed,
          optimizedByModel: optimizedByModel,
          revisedByApi: generated.revisedPrompt,
          usedReferenceImage: preparedRefs.isNotEmpty,
        );
        _updateGeneratedImage(
          working.id,
          assistantMsg.id,
          content: content,
          attachment: attachment,
          reasoning: reasoning,
          thinkingMillis: thinkingMillis,
          model: settings.imageGenerationApi.model,
        );
        await _recordImageVersion(
          output: attachment,
          settings: settings,
          originalPrompt: trimmed,
          sentPrompt: imagePrompt,
          revisedPrompt: generated.revisedPrompt,
          convoId: working.id,
          messageId: assistantMsg.id,
          references: preparedRefs,
          parentGenerationId: version?.id,
        );
        finishStep(resultCount: 1);
        _set(
          _s.copyWith(
            streamingConvoId: null,
            isGeneratingImage: false,
            error: null,
          ),
        );
        await _persistence.persistById(working.id);
        unawaited(
          GenerationNotify.onGenerationEnd(
            sessionId: _run?.conversationId,
            success: true,
            conversationTitle: working.title,
            preview: '图片已生成',
          ),
        );
        return true;
      } catch (e) {
        final cancelled = e is DioException && CancelToken.isCancel(e);
        finishStep(error: cancelled ? '已取消' : describeError(e));
        if (!cancelled) {
          _set(
            _s.copyWith(
              streamingConvoId: null,
              isGeneratingImage: false,
              error: describeError(e),
              errorConvoId: working.id,
              retryOperation: failureOperation,
            ),
          );
        } else {
          _set(_s.copyWith(isGeneratingImage: false));
        }
        await _persistence.persistById(working.id);
        unawaited(
          GenerationNotify.onGenerationEnd(
            sessionId: _run?.conversationId,
            success: false,
            conversationTitle: working.title,
            cancelled: cancelled,
          ),
        );
        return true;
      } finally {
        finishStep(error: cancelToken.isCancelled ? '已取消' : '未完成');
        if (_s.isGeneratingImage) {
          _set(_s.copyWith(isGeneratingImage: false));
        }
        _execution.releaseRequest(cancelToken);
      }
    } finally {
      _finishStarting();
    }
  });
}
