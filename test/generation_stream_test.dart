import 'dart:async';

import 'package:dio/dio.dart';
import 'package:expert_chat/domain/chat/generation_execution.dart';
import 'package:expert_chat/domain/chat/generation_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stop waits for stream cleanup before allowing a replacement turn',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      final cleanupStarted = Completer<void>();
      final cleanupReleased = Completer<void>();
      final source = StreamController<String>(
        onCancel: () {
          cleanupStarted.complete();
          return cleanupReleased.future;
        },
      );
      final token = CancelToken();
      execution.attachRequest(token);
      final received = <String>[];
      final running = execution.consumeStream(
        source.stream,
        cancelToken: token,
        onData: received.add,
      );
      final finished = running.whenComplete(execution.finish);
      final idle = execution.whenIdle;
      var becameIdle = false;
      unawaited(idle.then((_) => becameIdle = true));
      source.add('queued before stop');
      execution.cancel();
      source.add('late chunk');
      await cleanupStarted.future;
      await Future<void>.delayed(Duration.zero);
      expect(becameIdle, isFalse);
      expect(execution.tryStart(), isFalse);
      expect(received, isEmpty);
      cleanupReleased.complete();
      expect((await finished).end, GenerationStreamEnd.cancelled);
      await idle;
      expect(execution.tryStart(), isTrue);
      await source.close();
    },
  );

  test(
    'late cancellation of a previous request cannot stop its replacement',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      final oldToken = CancelToken();
      execution.attachRequest(oldToken);
      expect(
        (await execution.consumeStream(
          Stream.value('first'),
          cancelToken: oldToken,
          onData: (_) {},
        )).end,
        GenerationStreamEnd.completed,
      );
      final nextToken = CancelToken();
      execution.attachRequest(nextToken);
      execution.releaseRequest(oldToken);
      final source = StreamController<String>();
      final received = <String>[];
      final next = execution.consumeStream(
        source.stream,
        cancelToken: nextToken,
        onData: received.add,
      );
      oldToken.cancel();
      source.add('replacement');
      await source.close();
      expect((await next).end, GenerationStreamEnd.completed);
      expect(received, ['replacement']);
      expect(nextToken.isCancelled, isFalse);
      execution.cancel();
      expect(nextToken.isCancelled, isTrue);
    },
  );

  test('a pre-cancelled request never subscribes', () async {
    final execution = GenerationExecution()..tryStart();
    addTearDown(execution.dispose);
    var listened = false;
    final source = StreamController<String>(onListen: () => listened = true);
    final token = CancelToken()..cancel();
    final result = await execution.consumeStream(
      source.stream,
      cancelToken: token,
      onData: (_) => fail('cancelled data'),
    );
    expect(result.end, GenerationStreamEnd.cancelled);
    expect(listened, isFalse);
    unawaited(source.close());
  });

  for (final callbackFailure in [false, true]) {
    test(
      '${callbackFailure ? 'consumer' : 'provider'} failure cleans up and preserves the error',
      () async {
        final source = StreamController<String>();
        final error = StateError('original failure');
        final trace = StackTrace.current;
        final received = <String>[];
        final run = GenerationStream().consume(
          source.stream,
          onData: (value) {
            received.add(value);
            if (callbackFailure) Error.throwWithStackTrace(error, trace);
          },
        );
        if (callbackFailure) {
          source.add('first');
        } else {
          source.addError(error, trace);
        }
        source.add('must not arrive');
        final result = await run;
        expect(result.end, GenerationStreamEnd.failed);
        expect(result.error, same(error));
        expect(result.stackTrace, same(trace));
        expect(received, callbackFailure ? ['first'] : isEmpty);
        expect(source.hasListener, isFalse);
        await source.close();
      },
    );
  }

  test(
    'cancellation cleanup errors do not become uncaught async errors',
    () async {
      final source = StreamController<String>(
        onCancel: () async {
          throw StateError('cleanup failed');
        },
      );
      final stream = GenerationStream();
      final consumed = stream.consume(source.stream, onData: (_) {});
      stream.cancel();
      expect((await consumed).end, GenerationStreamEnd.cancelled);
      await source.close();
    },
  );
}
