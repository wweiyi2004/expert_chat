part of '../chat_controller.dart';

mixin ChatStreaming on ChatTools {
  /// Returns true when the stream finished with an answer (not cancelled/errored).
  Future<bool> _streamAnswer({
    required LlmConfig config,
    required List<LlmRequestMessage> history,
    required String convoId,
    required String assistantId,
    required bool thinking,
    required ReasoningEffort reasoningEffort,
    required SettingsState settings,
    required String fallbackSearchQuery,
    required bool enableTools,
    required List<ToolSpec> toolSpecs,
    required List<Citation> initialCitations,
    required Set<String> allowedFetchUrls,
    required CancelToken cancelToken,
    required _TurnImageBudget imageBudget,
    required ChatRetryOperation failureOperation,
    CharacterCard? imageCharacter,
    SearchBackend clientSearchBackend = SearchBackend.duckduckgo,
    String? forceToolName,
    bool workMode = false,
  }) async {
    final llm = ref.read(llmProvider);
    final requestMessages = List<LlmRequestMessage>.of(history);
    final usesComputer = toolSpecs.any((tool) {
      final routed = settings.routedMcpTool(tool.name);
      return routed != null && settings.connectionForRouted(routed).computerUse;
    });
    if (usesComputer) {
      requestMessages.insert(
        0,
        const LlmRequestMessage(
          role: MessageRole.system,
          content: ComputerUsePolicy.guidance,
        ),
      );
    }
    final computerClient = usesComputer ? ref.read(mcpClientProvider) : null;
    // Pre-fetch/pre-search citations must stay in the same numbering space as
    // citations produced by later model tool calls.
    final citations = List<Citation>.of(initialCitations);
    final output = StreamAnswerBuffer();
    var succeeded = false;
    var requestToken = cancelToken;
    var finalizing = false;
    var finalTimedOut = false;
    Timer? finalTimer;

    var cacheHitRate = 0.0;
    try {
      cacheHitRate =
          ref
              .read(modelUsageControllerProvider.notifier)
              .find(endpoint: config.baseUrl, model: config.model)
              ?.cacheHitRate ??
          0;
    } catch (_) {
      // Optional: tests and early init may not override SharedPreferences.
    }
    _streamHasLiveContent = false;
    final presenter = StreamAnswerPresenter(
      buffer: output,
      cacheHitRate: cacheHitRate,
      focusOf: () => _streamUiFocus,
      onPublish: (snapshot) => _updateAssistant(
        convoId,
        assistantId,
        snapshot.content,
        snapshot.reasoning,
        snapshot.thinkingMillis,
      ),
      onCheckpoint: () => _persistence.checkpointSoon(convoId),
    );
    void flushActiveStream() => presenter.flush(publishAll: true);
    _flushActiveStream = flushActiveStream;
    final void Function() nudgeStreamUi = presenter.nudge;
    _nudgeStreamUi = nudgeStreamUi;

    // Chat: N search rounds plus one tool-less wrap-up.
    // Work: keep calling tools until the model stops, with a safety wrap-up.
    final maxToolRounds = ToolLoopPolicy.maxRounds(
      workMode: workMode,
      searchMaxRounds: settings.searchMaxRounds,
    );
    try {
      for (var round = 0; round < maxToolRounds; round++) {
        if (_execution.isCancelled || !_s.isStreaming) return false;
        if ((_execution.budget?.finishing ?? false) && !finalizing) {
          finalizing = true;
          output.appendReasoningNote(
            '\n\n【任务提示】${_execution.budget!.reason}，正在整理答复。\n',
          );
          requestToken = CancelToken();
          _execution.attachRequest(requestToken);
          _endPendingActivities(convoId, assistantId, '已中断本地等待；远端状态未确认');
          requestMessages.add(
            LlmRequestMessage(
              role: MessageRole.system,
              content:
                  '${_execution.budget!.reason}。停止规划和工具调用，直接基于已有资料输出正文。'
                  '资料不足时说明限制，不得声称未完成的操作已成功。',
            ),
          );
          final saved = _messageById(convoId, assistantId);
          if (saved != null &&
              !requestMessages.any((m) => m.role == MessageRole.tool)) {
            requestMessages.add(
              LlmRequestMessage(
                role: MessageRole.system,
                content: RequestContextBuilder.savedResultsPrompt(saved),
              ),
            );
            final bounded = ref
                .read(contextWindowManagerProvider)
                .manage(requestMessages, settings.context);
            requestMessages
              ..clear()
              ..addAll(bounded.messages);
            if (settings.context.enabled &&
                bounded.report.sentTokens > bounded.report.inputBudgetTokens) {
              throw StateError('已有资料超过上下文预算，请减少资料后重试。');
            }
          }
          finalTimer = Timer(LlmRequestPolicy.finalAnswerTimeout, () {
            finalTimedOut = true;
            _execution.cancelRequest('final answer timeout');
          });
        }
        final toolDrafts = <int, ToolCallDraft>{};
        final turnContent = StringBuffer();
        final turnReasoning = StringBuffer();
        String? finishReason;

        // On the LAST round drop the tool list entirely so the model is forced
        // to answer from what it has, instead of us erroring out mid-answer.
        final request = LlmRequestPolicy.forRound(
          config: config,
          thinking: thinking,
          reasoningEffort: reasoningEffort,
          tools: toolSpecs,
          enableTools: enableTools,
          round: round,
          maxRounds: maxToolRounds,
          finalizing: finalizing,
          forceToolName: forceToolName,
        );
        final stream = llm.streamChat(
          config: request.config,
          messages: requestMessages,
          tools: request.tools,
          thinking: request.thinking,
          reasoningEffort: request.reasoningEffort,
          forceToolName: request.forceToolName,
          cancelToken: requestToken,
        );

        var turnResponseItems = <Map<String, dynamic>>[];
        final streamResult = await _execution.consumeStream(
          stream,
          cancelToken: requestToken,
          onData: (chunk) {
            finishReason = chunk.finishReason ?? finishReason;
            if (chunk.reasoningDelta != null &&
                chunk.reasoningDelta!.isNotEmpty) {
              _execution.budget?.resumeWork();
              turnReasoning.write(chunk.reasoningDelta!);
              presenter.addReasoning(chunk.reasoningDelta!);
            }
            if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
              if (chunk.contentDelta!.trim().isNotEmpty) {
                _execution.budget?.answerStarted();
                finalTimer?.cancel();
              }
              turnContent.write(chunk.contentDelta!);
              presenter.addContent(chunk.contentDelta!);
              _streamHasLiveContent = true;
            }
            for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
              _execution.budget?.resumeWork();
              (toolDrafts[call.index] ??= ToolCallDraft(
                call.index,
              )).merge(call);
            }
            if (chunk.serverSearchActivity != null) {
              _execution.budget?.resumeWork();
              // Stamp tool positions against all reasoning received so far,
              // not the last throttled UI snapshot.
              presenter.flush(publishAll: true);
              _upsertSearchActivity(
                convoId,
                assistantId,
                chunk.serverSearchActivity!,
              );
              if (chunk.serverSearchActivity!.status ==
                      SearchActivityStatus.running &&
                  _s.isStreaming) {
                _set(
                  _s.copyWith(
                    isSearching: true,
                    isGeneratingImage: false,
                    isProcessingDocument: false,
                  ),
                );
              } else if (chunk.serverSearchActivity!.status !=
                      SearchActivityStatus.running &&
                  _s.isStreaming) {
                _set(_s.copyWith(isSearching: false));
              }
            }
            if (chunk.citations != null && chunk.citations!.isNotEmpty) {
              // Merge by URL so repeated annotation events don't renumber.
              final known = {for (final c in citations) c.url};
              for (final c in chunk.citations!) {
                if (known.add(c.url)) {
                  citations.add(
                    Citation(
                      index: citations.length + 1,
                      title: c.title,
                      url: c.url,
                      snippet: c.snippet,
                    ),
                  );
                }
              }
              _setCitations(convoId, assistantId, List<Citation>.of(citations));
            }
            if (chunk.responseOutputItems != null) {
              turnResponseItems = chunk.responseOutputItems!;
            }
            presenter.scheduleFlush();
          },
        );
        if (!ref.mounted) return false;

        // The fake/test stream and very short real answers may finish before
        // the coalescing timer fires, so always publish pending content here.
        presenter.flush(publishAll: true);

        if (_execution.isCancelled || !_s.isStreaming) return false;
        if ((_execution.budget?.finishing ?? false) && !finalizing) {
          round--; // Reserve exactly one tool-free wrap-up, including at the cap.
          continue;
        }
        if (finalTimedOut) throw TimeoutException('任务已停止：整理答复未及时返回正文，请手动重试。');
        if (streamResult.error != null) {
          Error.throwWithStackTrace(
            streamResult.error!,
            streamResult.stackTrace ?? StackTrace.current,
          );
        }
        if (!_s.isStreaming) {
          await _persistence.persistSafely(convoId);
          return false;
        }

        if (output.isThinking) {
          output.stopThinking();
          presenter.flush(publishAll: true);
        }

        final outputLimited = _isOutputLimitFinish(finishReason);
        if (outputLimited ||
            finishReason == 'incomplete' ||
            finishReason == 'content_filter') {
          if (outputLimited &&
              output.content.trim().isEmpty &&
              turnReasoning.isNotEmpty) {
            output.replaceContent(_reasoningLimitFallback);
            presenter.flush(publishAll: true);
          }
          throw StateError(
            outputLimited
                ? '模型输出达到长度上限，答复尚未完成；已保留收到的内容，请重试或继续提问。'
                : '模型未完成答复（$finishReason）；已保留收到的内容，请重试。',
          );
        }

        final toolCalls = ToolCallDraft.finalize(toolDrafts);
        final needsTools =
            request.tools != null &&
            (toolCalls.isNotEmpty || finishReason == 'tool_calls');
        if (!needsTools) {
          // Some DeepSeek-compatible endpoints occasionally put the entire
          // final response in `reasoning_content` and leave `content` empty.
          // Recover only after a normally completed round. If the provider
          // reports an output-limit stop, the reasoning may be a truncated
          // chain and must not be presented as a finished answer.
          if (output.content.trim().isEmpty) {
            if (finalizing) {
              throw StateError('整理请求未返回正文，已停止。请检查已有结果后手动重试。');
            }
            final reasoningOnly = turnReasoning.toString().trim();
            output.replaceContent('');
            if (toolCalls.isNotEmpty) {
              // On the tool-withheld final round, reasoning that accompanies a
              // rejected tool call is not a final answer.
              output.replaceContent(_emptyReplyFallback);
            } else if (reasoningOnly.isNotEmpty) {
              final recovered = _splitReasoningOnlyReply(reasoningOnly);
              final allReasoning = output.reasoning;
              final priorLength = allReasoning.length - turnReasoning.length;
              final priorReasoning = priorLength <= 0
                  ? ''
                  : allReasoning.substring(0, priorLength);
              output.replaceReasoning(priorReasoning + recovered.reasoning);
              output.replaceContent(recovered.content);
            } else {
              // The final round withholds the tool list, but a stubborn model
              // may still emit tool calls (or nothing) without any text.
              output.replaceContent(_emptyReplyFallback);
            }

            presenter.flush(publishAll: true);
          }
          // A failed search / image gen earlier in this turn must not leave its
          // error banner behind once the model answered. Only this
          // conversation's scoped error is cleared; another conversation's
          // parked error stays (see selectConversation).
          final next = _s.copyWith(
            streamingConvoId: null,
            isSearching: false,
            isGeneratingImage: false,
            isProcessingDocument: false,
          );
          _set(_s.errorConvoId == convoId ? next.copyWith(error: null) : next);
          await _persistence.persistSafely(convoId);
          succeeded = true;
          return true;
        }

        if (toolCalls.isEmpty) {
          throw Exception('模型请求了工具调用，但没有返回可执行的工具参数。');
        }

        requestMessages.add(
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: turnContent.toString(),
            reasoningContent: turnReasoning.toString(),
            toolCalls: toolCalls,
            responseOutputItems: turnResponseItems,
          ),
        );

        // Clear transient "let me search" text from the visible answer. The
        // final response will stream in after tool results are appended.
        output.replaceContent('');
        presenter.flush(publishAll: true);

        final toolMessages = await _executeToolCalls(
          canSeeToolImages: config.capabilities.supportsVision,
          toolCalls: toolCalls,
          maxCallsPerRound: ToolLoopPolicy.maxCallsPerRound(workMode: workMode),
          settings: settings,
          fallbackSearchQuery: fallbackSearchQuery,
          convoId: convoId,
          assistantId: assistantId,
          citations: citations,
          allowedFetchUrls: allowedFetchUrls,
          cancelToken: requestToken,
          imageBudget: imageBudget,
          imageCharacter: imageCharacter,
          clientSearchBackend: clientSearchBackend,
          editableAttachments: _userAttachmentsForTurn(
            _s.conversations.firstWhere(
              (c) => c.id == convoId,
              orElse: () => Conversation(id: convoId),
            ),
            assistantId,
          ),
        );
        if (!_s.isStreaming) {
          await _persistence.persistSafely(convoId);
          return false;
        }
        ToolImageContext.append(requestMessages, toolMessages);

        // Tool responses can be much larger than the original conversation.
        // Re-budget before the next model round while keeping each assistant
        // tool-call and its tool results as an indivisible protocol unit.
        final roundContext = ref
            .read(contextWindowManagerProvider)
            .manage(requestMessages, settings.context);
        requestMessages
          ..clear()
          ..addAll(roundContext.messages);
        _recordContextReport(convoId, roundContext.report, accumulate: true);
        if (settings.context.enabled &&
            roundContext.report.sentTokens >
                roundContext.report.inputBudgetTokens) {
          throw Exception('工具结果超过上下文预算，请减少附件、关闭联网搜索，或在设置中增大上下文窗口。');
        }
      }
    } catch (e) {
      if (!ref.mounted) return false;
      presenter.flush(publishAll: true);
      output.stopThinking(recordElapsed: false);
      _set(
        _s.copyWith(
          streamingConvoId: null,
          isSearching: false,
          isGeneratingImage: false,
          isProcessingDocument: false,
          // A cancellation raised by stop() is not an error to surface.
          error: isCancelError(e) ? null : describeError(e),
          errorConvoId: isCancelError(e) ? null : convoId,
          retryOperation: isCancelError(e) ? null : failureOperation,
        ),
      );
      await _persistence.persistSafely(convoId);
      return false;
    } finally {
      finalTimer?.cancel();
      await computerClient?.stopLocalServers();
      if (ref.mounted) {
        _endPendingActivities(
          convoId,
          assistantId,
          _execution.isCancelled ? '已停止本地等待；远端状态未确认' : '步骤未完成',
        );
      }
      presenter.dispose();
      if (identical(_flushActiveStream, flushActiveStream)) {
        _flushActiveStream = null;
      }
      if (identical(_nudgeStreamUi, nudgeStreamUi)) {
        _nudgeStreamUi = null;
      }
      // Drop our token once finished so a later stop() can't cancel a stale one.
      _execution.releaseRequest(requestToken);
    }
    return succeeded;
  }

  static bool _isOutputLimitFinish(String? finishReason) {
    final value = finishReason?.trim().toLowerCase();
    return value == 'length' ||
        value == 'max_tokens' ||
        value == 'max_output_tokens';
  }

  /// Splits a misplaced reasoning-only response into the visible final answer
  /// and the optional reasoning that preceded an explicit final-answer marker.
  /// Without a marker, treat the whole payload as the answer: this is the
  /// common gateway failure mode and avoids showing the same text twice.
  static ({String content, String reasoning}) _splitReasoningOnlyReply(
    String raw,
  ) {
    final text = raw.trim();
    final lower = text.toLowerCase();
    final thinkClose = lower.lastIndexOf('</think>');
    if (thinkClose >= 0) {
      final answer = text.substring(thinkClose + '</think>'.length).trim();
      if (answer.isNotEmpty) {
        final thought = text
            .substring(0, thinkClose)
            .replaceFirst(RegExp(r'^\s*<think>\s*', caseSensitive: false), '')
            .trim();
        return (content: answer, reasoning: thought);
      }
    }

    final marker = RegExp(
      r'^[ \t]*(?:#{1,6}[ \t]*)?'
      r'(?:最终答案|最终答复|答案|final answer)'
      r'[ \t]*[:：]?[ \t]*',
      caseSensitive: false,
      multiLine: true,
    );
    final matches = marker.allMatches(text).toList();
    if (matches.isNotEmpty) {
      final last = matches.last;
      final answer = text.substring(last.end).trim();
      if (answer.isNotEmpty) {
        return (
          content: answer,
          reasoning: text.substring(0, last.start).trim(),
        );
      }
    }
    return (content: text, reasoning: '');
  }
}
