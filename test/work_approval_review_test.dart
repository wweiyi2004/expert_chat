import 'dart:async';

import 'package:dio/dio.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/work_approval_review.dart';
import 'package:flutter_test/flutter_test.dart';

const approval = '{"approve":true,"reason":"目标与范围明确"}';

void main() {
  for (final finish in [
    'stop',
    'length',
    'content_filter',
    'incomplete',
    'tool_calls',
    null,
  ]) {
    test(
      'review completion must be explicit and successful: $finish',
      () async {
        final task = CancelToken();
        final result = const WorkApprovalReview().run(
          taskToken: task,
          open: (_) => Stream.fromIterable([
            ChatChunk(contentDelta: approval, finishReason: finish),
          ]),
        );
        if (finish == 'stop') {
          expect((await result).approve, isTrue);
        } else {
          await expectLater(result, throwsFormatException);
        }
        expect(task.isCancelled, isFalse);
      },
    );
  }

  test('tool requests cannot be concealed by a successful finish', () async {
    await expectLater(
      const WorkApprovalReview().run(
        taskToken: CancelToken(),
        open: (_) => Stream.fromIterable([
          const ChatChunk(
            contentDelta: approval,
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'synthetic-call',
                name: 'write',
                argumentsJson: '{}',
              ),
            ],
          ),
          const ChatChunk(finishReason: 'stop'),
        ]),
      ),
      throwsFormatException,
    );
  });

  test('valid JSON followed by transport failure is not an approval', () async {
    Stream<ChatChunk> broken(CancelToken _) async* {
      yield const ChatChunk(contentDelta: approval, finishReason: 'stop');
      throw StateError('synthetic connection failure');
    }

    await expectLater(
      const WorkApprovalReview().run(taskToken: CancelToken(), open: broken),
      throwsStateError,
    );
  });

  test(
    'total deadline survives continuous chunks and slow cancellation',
    () async {
      final task = CancelToken();
      final cancelled = Completer<void>();
      final stream = StreamController<ChatChunk>(
        onCancel: () => cancelled.future,
      );
      late CancelToken request;
      final result =
          const WorkApprovalReview(timeout: Duration(milliseconds: 100)).run(
            taskToken: task,
            open: (token) {
              request = token;
              return stream.stream;
            },
          );
      final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
        stream.add(const ChatChunk(reasoningDelta: '.'));
      });
      try {
        await expectLater(
          result.timeout(const Duration(seconds: 2)),
          throwsA(isA<DioException>()),
        );
        expect(request.isCancelled, isTrue);
        expect(task.isCancelled, isFalse);
      } finally {
        heartbeat.cancel();
        cancelled.complete();
        unawaited(stream.close());
      }
    },
  );

  test('task cancellation cancels only its review request', () async {
    final task = CancelToken();
    late CancelToken request;
    final stream = StreamController<ChatChunk>();
    final result = const WorkApprovalReview().run(
      taskToken: task,
      open: (token) {
        request = token;
        return stream.stream;
      },
    );
    final checked = expectLater(result, throwsA(isA<DioException>()));
    task.cancel('user stop');
    await checked;
    expect(request.isCancelled, isTrue);
    await stream.close();
  });
}
