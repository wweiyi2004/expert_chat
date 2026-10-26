import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/work_request_retry.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';

void main() {
  test(
    'transient request retries bounded actual attempts with real backoff metadata',
    () async {
      var calls = 0;
      final retries = <Map<String, Object?>>[];
      Stream<ChatChunk> open() async* {
        calls++;
        if (calls < 3) {
          throw const LlmHttpException('temporary', statusCode: 429);
        }
        yield const ChatChunk(contentDelta: 'ok');
      }

      final chunks =
          await const WorkRequestRetry(baseDelay: Duration(milliseconds: 2))
              .run(
                open: open,
                token: CancelToken(),
                allowed: true,
                onRetry: (r) {
                  if (r != null) retries.add(r);
                },
              )
              .toList();
      expect(calls, 3);
      expect(chunks.single.contentDelta, 'ok');
      expect(retries.map((r) => r['attempt']), [2, 3]);
      expect(retries.map((r) => r['retry_after_ms']), [2, 4]);
    },
  );
  test(
    'Retry-After HTTP-date is parsed and cancel prevents actual second attempt',
    () async {
      final token = CancelToken();
      final retries = <Map<String, Object?>>[];
      final attempts = <int>[];
      Stream<ChatChunk> open() async* {
        throw DioException(
          requestOptions: RequestOptions(),
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': [
                HttpDate.format(
                  DateTime.now().add(const Duration(seconds: 15)),
                ),
              ],
            }),
          ),
        );
      }

      final done = expectLater(
        const WorkRequestRetry()
            .run(
              open: open,
              token: token,
              allowed: true,
              onAttempt: attempts.add,
              onRetry: (r) {
                if (r != null) {
                  retries.add(r);
                  token.cancel('done');
                }
              },
            )
            .toList(),
        throwsA(isA<DioException>()),
      );
      await done;
      expect(retries.single['retry_after_ms'], greaterThan(12000));
      expect(attempts, [1]);
    },
  );
  test('third transient failure ends, auth and fallback never retry', () async {
    for (final row in [
      (503, true, 3),
      (401, true, 1),
      (403, true, 1),
      (400, true, 1),
      (429, false, 1),
    ]) {
      var calls = 0;
      Stream<ChatChunk> open() async* {
        calls++;
        throw LlmHttpException('failure', statusCode: row.$1);
      }

      await expectLater(
        const WorkRequestRetry(
          baseDelay: Duration.zero,
        ).run(open: open, token: CancelToken(), allowed: row.$2).toList(),
        throwsA(isA<LlmHttpException>()),
      );
      expect(calls, row.$3);
    }
  });
  test(
    'any response output prevents replay including reasoning tools usage finish',
    () async {
      for (final chunk in [
        const ChatChunk(contentDelta: 'x'),
        const ChatChunk(reasoningDelta: 'x'),
        const ChatChunk(toolCalls: []),
        const ChatChunk(finishReason: 'stop'),
        const ChatChunk(usage: LlmUsage(inputTokens: 1, outputTokens: 0)),
      ]) {
        var calls = 0;
        Stream<ChatChunk> open() async* {
          calls++;
          yield chunk;
          throw const LlmHttpException('temporary', statusCode: 503);
        }

        await expectLater(
          const WorkRequestRetry(
            baseDelay: Duration.zero,
          ).run(open: open, token: CancelToken(), allowed: true).toList(),
          throwsA(isA<LlmHttpException>()),
        );
        expect(calls, 1);
      }
    },
  );
  test(
    'cancel during long backoff immediately ends and clears retry state',
    () async {
      final token = CancelToken();
      var calls = 0, clears = 0;
      final waiting = Completer<void>();
      Stream<ChatChunk> open() async* {
        calls++;
        throw const LlmHttpException('temporary', statusCode: 503);
      }

      final done = expectLater(
        const WorkRequestRetry(baseDelay: Duration(seconds: 30))
            .run(
              open: open,
              token: token,
              allowed: true,
              onRetry: (r) {
                if (r == null) {
                  clears++;
                } else if (!waiting.isCompleted) {
                  waiting.complete();
                }
              },
            )
            .toList(),
        throwsA(isA<DioException>()),
      );
      await waiting.future;
      final watch = Stopwatch()..start();
      token.cancel('test');
      await done;
      expect(watch.elapsedMilliseconds, lessThan(300));
      expect(calls, 1);
      expect(clears, greaterThan(0));
    },
  );
}
