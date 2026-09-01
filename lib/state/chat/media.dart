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

  Future<bool> _generateImageTurn(
    String prompt, {
    List<Attachment> referenceImages = const [],
    String? existingUserMessageId,
  }) async {
    final trimmed = prompt.trim();
    final refs = [
      for (final a in referenceImages)
        if (a.isImage && a.hasImageData) a,
    ];
    if (trimmed.isEmpty || _s.isStreaming || _starting) return false;
    _starting = true;
    _cancelStart = false;
    // Capture the originating conversation before the settings preflight: the
    // user may switch conversations while settings load, and the turn must
    // still target the conversation it started from (matching _generate).
    final originConvo = _s.current;
    try {
      final settings = await ref.read(settingsControllerProvider.future);
      if (!settings.imageGenerationConfigured) {
        _set(_s.copyWith(error: '请先在设置中完整配置图片生成 API。'));
        return false;
      }
      final useDeepThink = _s.deepThink;
      if (useDeepThink && !settings.config.isReady) {
        _set(_s.copyWith(error: '深度思考生图需要先配置对话 API（用于优化提示词）。'));
        return false;
      }
      if (_cancelStart) return false;

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
      _cancelToken = cancelToken;
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
      unawaited(GenerationNotify.onGenerationStart());
      try {
        await _persistence.persistById(working.id);
      } catch (e) {
        // Same contract as _generate: a transient local-storage failure must
        // not abort the turn (and must never strand streamingConvoId); the
        // final/checkpoint writes below retry through the serialized queue.
        _setScopedError('本地保存失败：$e', convoId: working.id);
      }

      try {
        var imagePrompt = trimmed;
        var optimizedByModel = '';
        var reasoning = '';
        var thinkingMillis = 0;

        if (useDeepThink) {
          final refined = await _optimizeImagePrompt(
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
          if (!_s.isStreaming || cancelToken.isCancelled) {
            await _persistence.persistById(working.id);
            unawaited(
              GenerationNotify.onGenerationEnd(
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

        final preparedRefs = <ImageEditReference>[];
        for (final reference in usedRefs) {
          final b64 = reference.imageBase64;
          if (b64 == null || b64.isEmpty) {
            _set(
              _s.copyWith(
                error: '参考图「${reference.name}」缺少本地数据，请重新从相册/文件选择。',
                errorConvoId: working.id,
                retryOperation: failureOperation,
                streamingConvoId: null,
              ),
            );
            await _persistence.persistById(working.id);
            unawaited(
              GenerationNotify.onGenerationEnd(
                success: false,
                conversationTitle: working.title,
              ),
            );
            return true;
          }
          try {
            // Large phone photos: decode base64 off the UI isolate, then
            // downscale on the UI isolate (target-bound decode).
            final raw = b64.length >= 256 * 1024
                ? await compute(base64Decode, b64)
                : base64Decode(b64);
            final prepared = await ImageCodecUtil.prepareReferenceImage(
              Uint8List.fromList(raw),
              mimeType: reference.mimeType,
              name: reference.name,
            );
            preparedRefs.add(
              ImageEditReference(
                bytes: prepared.bytes,
                mimeType: prepared.mimeType,
                fileName: prepared.name,
              ),
            );
          } on FormatException {
            _setScopedError(
              '参考图「${reference.name}」数据无效，请重新选择图片。',
              convoId: working.id,
              retryOperation: failureOperation,
            );
            _set(_s.copyWith(streamingConvoId: null));
            await _persistence.persistById(working.id);
            unawaited(
              GenerationNotify.onGenerationEnd(
                success: false,
                conversationTitle: working.title,
              ),
            );
            return true;
          }
        }

        if (_s.isStreaming) {
          _set(
            _s.copyWith(
              isGeneratingImage: true,
              isSearching: false,
              isProcessingDocument: false,
            ),
          );
        }
        final generated = await ref
            .read(mediaApiProvider)
            .generateImage(
              config: settings.imageGenerationApi,
              apiKey: settings.imageGenerationApiKey,
              prompt: imagePrompt,
              cancelToken: cancelToken,
              referenceImages: preparedRefs,
            );
        if (!_s.isStreaming || cancelToken.isCancelled) {
          await _persistence.persistById(working.id);
          unawaited(
            GenerationNotify.onGenerationEnd(
              success: false,
              conversationTitle: working.title,
              cancelled: true,
            ),
          );
          return true;
        }
        final sizeBytes = generated.base64 == null
            ? 0
            : (generated.base64!.length * 3 / 4).round();
        final attachment = Attachment(
          name: libraryGeneratedImageName(
            prompt: imagePrompt,
            mimeType: generated.mimeType,
          ),
          mimeType: generated.mimeType,
          sizeBytes: sizeBytes,
          imageBase64: generated.base64,
          remoteUrl: generated.remoteUrl,
        );
        unawaited(_importImageToLibrary(attachment));
        final content = _imageGenResultContent(
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
            success: true,
            conversationTitle: working.title,
            preview: '图片已生成',
          ),
        );
        return true;
      } catch (e) {
        final cancelled = e is DioException && CancelToken.isCancel(e);
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
            success: false,
            conversationTitle: working.title,
            cancelled: cancelled,
          ),
        );
        return true;
      } finally {
        if (_s.isGeneratingImage) {
          _set(_s.copyWith(isGeneratingImage: false));
        }
        if (identical(_cancelToken, cancelToken)) _cancelToken = null;
      }
    } finally {
      _finishStarting();
    }
  }

  static String _imageGenResultContent({
    required String originalPrompt,
    required String optimizedByModel,
    String? revisedByApi,
    bool usedReferenceImage = false,
  }) {
    final parts = <String>[usedReferenceImage ? '图片已生成（图生图）' : '图片已生成'];
    final opt = optimizedByModel.trim();
    final revised = revisedByApi?.trim() ?? '';
    if (opt.isNotEmpty && opt != originalPrompt.trim()) {
      parts.add('深度思考优化后的提示词：$opt');
    }
    if (revised.isNotEmpty &&
        revised != opt &&
        revised != originalPrompt.trim()) {
      parts.add('生图接口改写：$revised');
    }
    if (parts.length == 1 && revised.isNotEmpty) {
      parts.add('优化后的提示词：$revised');
    }
    return parts.join('\n\n');
  }
}
