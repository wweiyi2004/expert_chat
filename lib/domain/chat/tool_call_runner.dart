import 'dart:async';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'generation_execution.dart';

/// Executes a model's tool batch sequentially and returns one protocol reply
/// for every requested call, including calls skipped by cancellation/limits.
class ToolCallRunner {
  const ToolCallRunner(this.execution);

  final GenerationExecution execution;

  Future<List<LlmRequestMessage>> run({
    required List<ToolCall> calls,
    required int maxCalls,
    required CancelToken cancelToken,
    required FutureOr<String> Function(ToolCall call) execute,
    void Function(ToolCall call)? onStart,
    void Function(ToolCall call, String content)? onResult,
  }) => execution.runTools(() async {
    final replies = <LlmRequestMessage>[];
    for (var index = 0; index < calls.length; index++) {
      final call = calls[index];
      onStart?.call(call);
      final String content;
      if (index >= maxCalls) {
        content = '本轮最多执行 $maxCalls 次工具调用；其余请求已跳过。';
      } else if (execution.isCancelled ||
          cancelToken.isCancelled ||
          !(execution.budget?.takeTool() ?? true)) {
        content = '未执行：${execution.budget?.reason ?? '本地请求已停止'}。请基于已有资料回答。';
      } else {
        content = await execute(call);
      }
      onResult?.call(call, content);
      replies.add(
        LlmRequestMessage(
          role: MessageRole.tool,
          content: content,
          toolCallId: call.id ?? '',
        ),
      );
    }
    return replies;
  });
}
