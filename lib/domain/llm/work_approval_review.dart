import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'llm_provider.dart';

/// A review is advisory until its entire response has completed successfully.
/// Its deadline and cancellation are independent of the task's cancellation.
class WorkApprovalReview {
  const WorkApprovalReview({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  Future<({bool approve, String reason})> run({
    required CancelToken taskToken,
    required Stream<ChatChunk> Function(CancelToken token) open,
    void Function(ChatChunk chunk)? onChunk,
  }) async {
    final reviewToken = CancelToken();
    if (taskToken.isCancelled) throw taskToken.cancelError!;
    var finished = false;
    unawaited(
      taskToken.whenCancel.then((error) {
        if (!finished) reviewToken.cancel(error);
      }),
    );
    final deadline = Timer(
      timeout,
      () => reviewToken.cancel('review deadline'),
    );
    StreamIterator<ChatChunk>? iterator;
    try {
      iterator = StreamIterator(open(reviewToken));
      final content = StringBuffer();
      var characters = 0;
      var complete = false;
      while (await Future.any<bool>([
        iterator.moveNext(),
        reviewToken.whenCancel.then<bool>((error) => throw error),
      ])) {
        if (reviewToken.isCancelled) throw reviewToken.cancelError!;
        final chunk = iterator.current;
        onChunk?.call(chunk);
        if (chunk.toolCalls?.isNotEmpty == true ||
            chunk.serverSearchActivity != null ||
            (chunk.responseOutputItems ?? const []).any(
              (item) =>
                  item['type'] == 'function_call' ||
                  item['type'] == 'tool_use' ||
                  item.containsKey('functionCall'),
            )) {
          throw const FormatException('评判不能调用工具');
        }
        final finish = chunk.finishReason;
        if (finish != null) {
          // All four provider adapters normalize successful completion to stop.
          if (finish != 'stop') throw const FormatException('评判未正常完成');
          complete = true;
        }
        characters +=
            (chunk.contentDelta?.length ?? 0) +
            (chunk.reasoningDelta?.length ?? 0);
        if (characters > 8000) throw const FormatException('评判输出过长');
        content.write(chunk.contentDelta ?? '');
      }
      if (reviewToken.isCancelled) throw reviewToken.cancelError!;
      if (!complete) throw const FormatException('评判缺少完成状态');
      final decoded = jsonDecode(
        content
            .toString()
            .trim()
            .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
            .replaceFirst(RegExp(r'\s*```$'), ''),
      );
      if (decoded is! Map ||
          decoded['approve'] is! bool ||
          decoded['reason'] is! String ||
          (decoded['reason'] as String).trim().isEmpty ||
          decoded.keys.any((key) => key != 'approve' && key != 'reason')) {
        throw const FormatException('评判未返回有效结论');
      }
      return (
        approve: decoded['approve'] as bool,
        reason: (decoded['reason'] as String).trim(),
      );
    } finally {
      finished = true;
      deadline.cancel();
      reviewToken.cancel('review finished');
      // A misbehaving provider's cancellation must not delay manual approval.
      if (iterator != null) {
        unawaited(iterator.cancel().catchError((Object _) {}));
      }
    }
  }
}
