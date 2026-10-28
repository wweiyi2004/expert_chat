import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import '../llm/llm_provider.dart';
import 'error_describe.dart';
import 'generation_execution.dart';

/// Thrown by a [ToolCallRunner.run] `prepare` hook to answer a call with
/// [message] without executing it.
class ToolCallRejected implements Exception {
  const ToolCallRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Executes a model's tool batch and returns one protocol reply for every
/// requested call, in request order, including calls skipped by
/// cancellation/limits. Consecutive calls accepted by `concurrent` run
/// together; everything else runs one at a time.
class ToolCallRunner {
  const ToolCallRunner(this.execution);

  final GenerationExecution execution;

  /// [maxCalls] caps one batch; null leaves the batch to the task budget.
  /// [prepare] may rewrite a call before it starts (the reply keeps the
  /// original call id); the rewritten call reaches [onStart], [execute] and
  /// [onResult]. [concurrent] marks side-effect-free calls that may overlap;
  /// [sideEffectFree] marks calls whose throw is a definite failure. Other
  /// throws report an unknown outcome and skip the rest of the batch.
  Future<List<LlmRequestMessage>> run({
    required List<ToolCall> calls,
    int? maxCalls,
    required CancelToken cancelToken,
    required FutureOr<String> Function(ToolCall call) execute,
    Future<ToolCall> Function(ToolCall call)? prepare,
    bool Function(ToolCall call)? concurrent,
    bool Function(ToolCall call)? sideEffectFree,
    void Function(ToolCall call)? onStart,
    void Function(ToolCall call, String content)? onResult,
  }) => execution.runTools(() async {
    final replies = <LlmRequestMessage>[];
    // After an unexpected failure, later calls of the same batch may depend on
    // it (copy then delete), so they are answered but not run.
    String? failedTool;
    Future<String> guarded(ToolCall call) async {
      try {
        return await execute(call);
      } catch (error) {
        if (isCancelError(error) ||
            execution.isCancelled ||
            cancelToken.isCancelled) {
          rethrow;
        }
        // One failing tool is a result for the model, not a failed task.
        final name = call.name ?? '工具';
        if (sideEffectFree?.call(call) == true) {
          return jsonEncode({
            'ok': false,
            'execution_outcome': 'failed',
            'error': '$name 执行出错：${describeError(error)}',
          });
        }
        failedTool ??= name;
        return jsonEncode({
          'ok': false,
          'execution_outcome': 'unknown',
          'error':
              '$name 执行出错：${describeError(error)}。副作用可能已发生，请先核对目标状态再决定是否重试。',
        });
      }
    }

    for (var index = 0; index < calls.length;) {
      var end = index + 1;
      if (concurrent != null && concurrent(calls[index])) {
        while (end < calls.length && concurrent(calls[end])) {
          end++;
        }
      }
      final started = <(ToolCall, String?)>[];
      for (var i = index; i < end; i++) {
        var call = calls[i];
        String? skipped;
        if (maxCalls != null && i >= maxCalls) {
          skipped = '本轮最多执行 $maxCalls 次工具调用；其余请求已跳过。';
        } else if (failedTool != null) {
          skipped = '未执行：同一批次中前面的 $failedTool 出错，后续调用可能依赖其结果，已跳过。请核对后重新发起。';
        } else if (execution.isCancelled ||
            cancelToken.isCancelled ||
            !(execution.budget?.takeTool() ?? true)) {
          skipped = '未执行：${execution.budget?.reason ?? '本地请求已停止'}。请基于已有资料回答。';
        } else if (prepare != null) {
          try {
            call = await prepare(call);
          } on ToolCallRejected catch (rejected) {
            skipped = rejected.message;
          }
        }
        onStart?.call(call);
        started.add((call, skipped));
      }
      final contents = await Future.wait([
        for (final (call, skipped) in started)
          skipped != null ? Future.value(skipped) : guarded(call),
      ]);
      for (var j = 0; j < started.length; j++) {
        final call = started[j].$1, content = contents[j];
        onResult?.call(call, content);
        replies.add(
          LlmRequestMessage(
            role: MessageRole.tool,
            content: content,
            toolCallId: calls[index + j].id ?? '',
          ),
        );
      }
      index = end;
    }
    return replies;
  });
}
