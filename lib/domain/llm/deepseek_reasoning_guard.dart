import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';
import 'llm_provider.dart';
import 'llm_request_policy.dart';

/// Bounds reasoning before an answer/tool call, without limiting answer length.
/// A single non-thinking retry keeps the original messages and tool results.
class DeepSeekReasoningGuard implements LlmProvider {
  DeepSeekReasoningGuard({
    required this.delegate,
    this.reasoningTimeout = LlmRequestPolicy.reasoningTimeout,
    this.maxReasoningChars = LlmRequestPolicy.maxReasoningChars,
    this.recoveryTimeout = LlmRequestPolicy.recoveryTimeout,
    this.maxRecoveryChars = LlmRequestPolicy.maxRecoveryChars,
  });

  final LlmProvider delegate;
  final Duration reasoningTimeout;
  final int maxReasoningChars;
  final Duration recoveryTimeout;
  final int maxRecoveryChars;

  static const _instruction =
      '请简短思考并及时推进任务；需要搜索或生图时直接调用对应工具，'
      '不要反复描述准备执行的动作。资料足够后结束思考，将最终答复输出到正文 content，'
      '不要只在 reasoning_content 中给出答案。'
      '翻译、润色、改写和小说正文生成时，仅做完成任务所必需的简短准备。'
      '不要在思考中生成整篇译文、完整场景或多个候选草稿；不要逐句预演正文，'
      '也不要反复比较近义表达。确定关键术语、视角和连续性后，直接输出完整正文。'
      '只有发现具体矛盾或实质错误时才重新检查，避免重复规划和无新增信息的自我复核。'
      '简短思考不得以缩短、遗漏正文为代价。用户明确要求大纲、方案比较或审校时，'
      '将所需大纲、比较或审校结果作为正式答复输出。';
  static const _recoveryInstruction =
      '本次请直接给出面向用户的答复，不再展开思考或重复规划。'
      '利用对话中已有的资料和工具结果；只有缺少必要信息时才调用工具。'
      '不确定的内容明确说明，最终答复必须输出到正文 content。'
      '翻译和写作请直接输出完整译文或正文，不再生成草稿、重复推敲或复述写作计划；'
      '保留用户要求的篇幅、细节和格式，不要用摘要代替正文。';

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    if (!config.isDeepSeek || !config.reasoningGuardEnabled) {
      yield* delegate.streamChat(
        config: config,
        messages: messages,
        tools: tools,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        forceToolName: forceToolName,
        cancelToken: cancelToken,
      );
      return;
    }

    for (
      var attempt = 0;
      attempt < LlmRequestPolicy.maxReasoningAttempts;
      attempt++
    ) {
      if (cancelToken?.isCancelled ?? false) return;
      final recovering = attempt > 0;
      final policy = LlmRequestPolicy.reasoningAttempt(
        config: config,
        attempt: attempt,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        timeout: reasoningTimeout,
        charLimit: maxReasoningChars,
        retryTimeout: recoveryTimeout,
        retryCharLimit: maxRecoveryChars,
      );
      try {
        await for (final chunk in _boundedAttempt(
          config: policy.config,
          messages: _instruct(
            messages,
            recovering ? _recoveryInstruction : _instruction,
          ),
          tools: tools,
          thinking: policy.thinking,
          reasoningEffort: policy.reasoningEffort,
          forceToolName: forceToolName,
          parentToken: cancelToken,
          timeout: policy.timeout,
          charLimit: policy.charLimit,
        )) {
          yield chunk;
        }
        return;
      } on _ReasoningLimit {
        if (cancelToken?.isCancelled ?? false) return;
        if (!policy.mayRetry) {
          throw StateError('模型仍未输出正文，已停止本次请求。请关闭深度思考后重试，或切换模型。');
        }
        yield const ChatChunk(
          reasoningDelta: '\n\n【系统提示】思考达到上限或未返回正文，正在关闭思考并整理答复…\n',
        );
      }
    }
  }

  Stream<ChatChunk> _boundedAttempt({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    required List<ToolSpec>? tools,
    required bool? thinking,
    required ReasoningEffort? reasoningEffort,
    required String? forceToolName,
    required CancelToken? parentToken,
    required Duration timeout,
    required int charLimit,
  }) {
    final token = CancelToken();
    final clock = Stopwatch();
    final runningSearches = <String>{};
    StreamSubscription<ChatChunk>? subscription;
    Timer? timer;
    var finished = false;
    var hasOutput = false;
    var reasoningChars = 0;
    late final StreamController<ChatChunk> output;

    void finish({Object? error, StackTrace? stack}) {
      if (finished) return;
      finished = true;
      timer?.cancel();
      clock.stop();
      if (error != null) output.addError(error, stack);
      token.cancel('reasoning guard complete');
      unawaited(subscription?.cancel());
      unawaited(output.close());
    }

    void armTimer() {
      timer?.cancel();
      if (hasOutput || reasoningChars == 0 || runningSearches.isNotEmpty) {
        clock.stop();
        return;
      }
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        finish(error: const _ReasoningLimit());
        return;
      }
      clock.start();
      timer = Timer(remaining, () => finish(error: const _ReasoningLimit()));
    }

    output = StreamController<ChatChunk>(
      onListen: () {
        if (parentToken?.isCancelled ?? false) {
          finish();
          return;
        }
        unawaited(parentToken?.whenCancel.then((_) => finish()));
        subscription = delegate
            .streamChat(
              config: config,
              messages: messages,
              tools: tools,
              thinking: thinking,
              reasoningEffort: reasoningEffort,
              forceToolName: forceToolName,
              cancelToken: token,
            )
            .listen(
              (chunk) {
                if (finished) return;
                hasOutput =
                    hasOutput ||
                    (chunk.contentDelta?.trim().isNotEmpty ?? false) ||
                    (chunk.toolCalls?.isNotEmpty ?? false);
                reasoningChars += chunk.reasoningDelta?.length ?? 0;
                final activity = chunk.serverSearchActivity;
                if (activity != null) {
                  if (activity.status == SearchActivityStatus.running) {
                    runningSearches.add(activity.id);
                  } else {
                    runningSearches.remove(activity.id);
                  }
                }
                if (!hasOutput && reasoningChars > charLimit) {
                  finish(error: const _ReasoningLimit());
                  return;
                }
                output.add(chunk);
                armTimer();
              },
              onError: (Object error, StackTrace stack) {
                finish(error: error, stack: stack);
              },
              onDone: () {
                finish(error: hasOutput ? null : const _ReasoningLimit());
              },
            );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        finished = true;
        timer?.cancel();
        clock.stop();
        token.cancel('stream closed');
        await subscription?.cancel();
      },
    );
    return output.stream;
  }

  static List<LlmRequestMessage> _instruct(
    List<LlmRequestMessage> messages,
    String instruction,
  ) {
    final index = messages.indexWhere((m) => m.role == MessageRole.system);
    if (index < 0) {
      return [
        LlmRequestMessage(role: MessageRole.system, content: instruction),
        ...messages,
      ];
    }
    return [
      for (var i = 0; i < messages.length; i++)
        if (i == index)
          LlmRequestMessage(
            role: MessageRole.system,
            content: '${messages[i].content}\n\n$instruction',
          )
        else
          messages[i],
    ];
  }
}

class _ReasoningLimit implements Exception {
  const _ReasoningLimit();
}
