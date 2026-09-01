part of '../chat_controller.dart';

mixin ChatStreaming on ChatTools {
  /// Returns true when the stream finished with an answer (not cancelled/errored).
  Future<bool> _streamAnswer({
    required LlmConfig config,
    required List<LlmRequestMessage> history,
    required String convoId,
    required String assistantId,
    required bool thinking,
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
    // Pre-fetch/pre-search citations must stay in the same numbering space as
    // citations produced by later model tool calls.
    final citations = List<Citation>.of(initialCitations);
    final content = StringBuffer();
    final reasoning = StringBuffer();
    // Stopwatch for "已深度思考 N 秒": starts on first reasoning delta, freezes
    // once real answer content begins streaming.
    final thinkClock = Stopwatch();
    var thinkMillis = 0;
    var succeeded = false;

    Timer? uiFlushTimer;
    Duration? uiFlushDelay;
    var uiDirty = false;
    var lastCheckpointAt = DateTime.now();
    var lastCheckpointLength = 0;
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
    var publishedContent = '';
    var publishedReasoning = '';
    final uiCoalescer = DualStreamUiCoalescer(
      cacheHitRate: cacheHitRate,
      focusOf: () => _streamUiFocus,
    );

    void flushUi({bool publishAll = false}) {
      uiFlushTimer?.cancel();
      uiFlushTimer = null;
      uiFlushDelay = null;
      if (!uiDirty && !publishAll) return;
      uiDirty = false;
      final focus = _streamUiFocus;
      final publishReasoning =
          publishAll ||
          focus == StreamUiFocus.away ||
          focus == StreamUiFocus.reasoning;
      final publishContent =
          publishAll ||
          focus == StreamUiFocus.away ||
          focus == StreamUiFocus.content;
      if (publishReasoning) publishedReasoning = reasoning.toString();
      if (publishContent) publishedContent = content.toString();
      uiCoalescer.markFlushed(all: publishAll);
      _updateAssistant(
        convoId,
        assistantId,
        publishedContent,
        publishedReasoning,
        thinkMillis,
      );

      final totalLength = content.length + reasoning.length;
      final now = DateTime.now();
      if (totalLength > 0 &&
          (now.difference(lastCheckpointAt) >= _checkpointInterval ||
              totalLength - lastCheckpointLength >= _checkpointChars)) {
        lastCheckpointAt = now;
        lastCheckpointLength = totalLength;
        // Checkpoints are best-effort; the final awaited write below remains
        // the authoritative persistence error surface.
        _persistence.checkpointSoon(convoId);
      }
    }

    void scheduleUiFlush() {
      uiDirty = true;
      if (uiCoalescer.shouldFlushNow) {
        flushUi();
        return;
      }
      if (_streamUiFocus != StreamUiFocus.away &&
          !uiCoalescer.focusedHasPending) {
        return;
      }
      final delay = uiCoalescer.delay;
      // Keep an in-flight timer unless the other pane needs a shorter wait
      // (typical: answer tokens arriving after a long think fallback).
      if (uiFlushTimer != null &&
          uiFlushDelay != null &&
          delay >= uiFlushDelay!) {
        return;
      }
      uiFlushTimer?.cancel();
      uiFlushDelay = delay;
      uiFlushTimer = Timer(delay, flushUi);
    }

    late final void Function() flushActiveStream;
    flushActiveStream = () => flushUi(publishAll: true);
    _flushActiveStream = flushActiveStream;
    late final void Function() nudgeStreamUi;
    nudgeStreamUi = () {
      uiDirty = true;
      flushUi();
    };
    _nudgeStreamUi = nudgeStreamUi;

    // Chat: N search rounds plus one tool-less wrap-up.
    // Work: keep calling tools until the model stops, with a safety wrap-up.
    final maxToolRounds = ToolLoopPolicy.maxRounds(
      workMode: workMode,
      searchMaxRounds: settings.searchMaxRounds,
    );
    try {
      for (var round = 0; round < maxToolRounds; round++) {
        final toolDrafts = <int, ToolCallDraft>{};
        final turnContent = StringBuffer();
        final turnReasoning = StringBuffer();
        String? finishReason;
        Object? streamError;

        // On the LAST round drop the tool list entirely so the model is forced
        // to answer from what it has, instead of us erroring out mid-answer.
        final allowTools = ToolLoopPolicy.allowToolsThisRound(
          workMode: workMode,
          round: round,
          maxRounds: maxToolRounds,
          enableTools: enableTools,
          hasToolSpecs: toolSpecs.isNotEmpty,
        );
        // Force hosted search only on the first model round; later rounds are
        // for answering after client function tools and must not re-trigger
        // tool_choice: web_search.
        final roundConfig = round == 0
            ? config
            : config.copyWith(forceServerWebSearch: false);
        final stream = llm.streamChat(
          config: roundConfig,
          messages: requestMessages,
          tools: allowTools ? toolSpecs : null,
          thinking: thinking,
          reasoningEffort: thinking ? _s.reasoningEffort : null,
          // Force only on the first tool-enabled round so later answer rounds
          // are free to write the final reply.
          forceToolName: allowTools && round == 0 ? forceToolName : null,
          cancelToken: cancelToken,
        );
        final completer = Completer<void>();
        _streamCompleter = completer;

        var turnResponseItems = <Map<String, dynamic>>[];
        _sub = stream.listen(
          (chunk) {
            finishReason = chunk.finishReason ?? finishReason;
            if (chunk.reasoningDelta != null &&
                chunk.reasoningDelta!.isNotEmpty) {
              // Restart across tool rounds too: the clock is stopped by the
              // previous round's answer content, and reasoning from later
              // rounds must keep accumulating into the reported thinking time.
              if (!thinkClock.isRunning) {
                thinkClock.start();
              }
              turnReasoning.write(chunk.reasoningDelta!);
              reasoning.write(chunk.reasoningDelta!);
              uiCoalescer.addReasoning(chunk.reasoningDelta!);
            }
            if (chunk.contentDelta != null && chunk.contentDelta!.isNotEmpty) {
              if (thinkClock.isRunning) {
                thinkClock.stop();
                thinkMillis = thinkClock.elapsedMilliseconds;
              }
              turnContent.write(chunk.contentDelta!);
              content.write(chunk.contentDelta!);
              _streamHasLiveContent = true;
              uiCoalescer.addContent(chunk.contentDelta!);
            }
            for (final call in chunk.toolCalls ?? const <ToolCall>[]) {
              (toolDrafts[call.index] ??= ToolCallDraft(
                call.index,
              )).merge(call);
            }
            if (chunk.serverSearchActivity != null) {
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
              } else if (chunk.serverSearchActivity!.status ==
                      SearchActivityStatus.done &&
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
            scheduleUiFlush();
          },
          onError: (Object e) {
            streamError = e;
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

        await completer.future;
        if (identical(_streamCompleter, completer)) _streamCompleter = null;
        _sub = null;

        // The fake/test stream and very short real answers may finish before
        // the coalescing timer fires, so always publish pending content here.
        uiDirty = true;
        flushUi(publishAll: true);

        if (streamError != null) throw streamError!;
        if (!_s.isStreaming) {
          await _persistence.persistSafely(convoId);
          return false;
        }

        if (thinkClock.isRunning) {
          thinkClock.stop();
          thinkMillis = thinkClock.elapsedMilliseconds;
          uiDirty = true;
          flushUi(publishAll: true);
        }

        final toolCalls = ToolCallDraft.finalize(toolDrafts);
        final needsTools =
            allowTools &&
            (toolCalls.isNotEmpty || finishReason == 'tool_calls');
        if (!needsTools) {
          // Some DeepSeek-compatible endpoints occasionally put the entire
          // final response in `reasoning_content` and leave `content` empty.
          // Recover only after a normally completed round. If the provider
          // reports an output-limit stop, the reasoning may be a truncated
          // chain and must not be presented as a finished answer.
          if (content.toString().trim().isEmpty) {
            final reasoningOnly = turnReasoning.toString().trim();
            content.clear();
            if (toolCalls.isNotEmpty) {
              // On the tool-withheld final round, reasoning that accompanies a
              // rejected tool call is not a final answer.
              content.write(_emptyReplyFallback);
            } else if (reasoningOnly.isNotEmpty &&
                !_isOutputLimitFinish(finishReason)) {
              final recovered = _splitReasoningOnlyReply(reasoningOnly);
              final allReasoning = reasoning.toString();
              final priorLength = allReasoning.length - turnReasoning.length;
              final priorReasoning = priorLength <= 0
                  ? ''
                  : allReasoning.substring(0, priorLength);
              reasoning
                ..clear()
                ..write(priorReasoning)
                ..write(recovered.reasoning);
              content.write(recovered.content);
            } else if (reasoningOnly.isNotEmpty) {
              content.write(_reasoningLimitFallback);
            } else {
              // The final round withholds the tool list, but a stubborn model
              // may still emit tool calls (or nothing) without any text.
              content.write(_emptyReplyFallback);
            }
            uiDirty = true;
            flushUi(publishAll: true);
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
        content.clear();
        publishedContent = '';
        uiDirty = true;
        flushUi(publishAll: true);

        final toolMessages = await _executeToolCalls(
          toolCalls: toolCalls,
          maxCallsPerRound: ToolLoopPolicy.maxCallsPerRound(workMode: workMode),
          settings: settings,
          fallbackSearchQuery: fallbackSearchQuery,
          convoId: convoId,
          assistantId: assistantId,
          citations: citations,
          allowedFetchUrls: allowedFetchUrls,
          cancelToken: cancelToken,
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
        requestMessages.addAll(toolMessages);

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
      uiDirty = true;
      flushUi(publishAll: true);
      if (thinkClock.isRunning) thinkClock.stop();
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
      uiFlushTimer?.cancel();
      if (identical(_flushActiveStream, flushActiveStream)) {
        _flushActiveStream = null;
      }
      if (identical(_nudgeStreamUi, nudgeStreamUi)) {
        _nudgeStreamUi = null;
      }
      // Drop our token once finished so a later stop() can't cancel a stale one.
      if (identical(_cancelToken, cancelToken)) _cancelToken = null;
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
