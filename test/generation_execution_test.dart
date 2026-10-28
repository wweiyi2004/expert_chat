import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/chat/generation_execution.dart';
import 'package:expert_chat/domain/chat/tool_call_runner.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCall _call(String id) =>
    ToolCall(index: 0, id: id, name: 'example', argumentsJson: '{}');

void main() {
  test(
    'prepare rewrites a call before start, rejections skip execution, reply keeps the original id',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      final started = <String>[], executed = <String>[], results = <String>[];
      final replies = await ToolCallRunner(execution).run(
        calls: [_call('a'), _call('b')],
        cancelToken: CancelToken(),
        prepare: (call) async {
          if (call.id == 'b') throw const ToolCallRejected('rejected b');
          return ToolCall(index: 0, id: call.id, name: 'rewritten');
        },
        onStart: (call) => started.add('${call.id}:${call.name}'),
        execute: (call) {
          executed.add('${call.id}:${call.name}');
          return 'done';
        },
        onResult: (call, _) => results.add('${call.id}:${call.name}'),
      );
      expect(started, ['a:rewritten', 'b:example']);
      expect(executed, ['a:rewritten']);
      expect(results, ['a:rewritten', 'b:example']);
      expect(replies.map((r) => r.toolCallId), ['a', 'b']);
      expect(replies.map((r) => r.content), ['done', 'rejected b']);
    },
  );

  test(
    'cancel holds the acceptance guard until async cleanup finishes',
    () async {
      final execution = GenerationExecution();
      addTearDown(execution.dispose);
      expect(execution.tryStart(), isTrue);
      expect(execution.tryStart(), isFalse);
      var idle = false;
      final waiting = execution.whenIdle.then((_) => idle = true);
      execution.cancel();
      await Future<void>.value();
      expect(idle, isFalse);
      expect(execution.tryStart(), isFalse);
      execution.finish();
      await waiting;
      expect(idle, isTrue);
      expect(execution.tryStart(), isTrue);
      expect(execution.isCancelled, isFalse);
    },
  );

  test(
    'budget exhaustion cancels a request and allows one final-answer phase',
    () {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      final request = CancelToken();
      execution.attachRequest(request);
      var flushed = false;
      execution.beginBudget(
        const TaskBudgetPrefs(maxToolCalls: 1),
        beforeCancel: () {
          expect(request.isCancelled, isFalse);
          flushed = true;
        },
      );
      expect(execution.budget!.takeTool(), isTrue);
      expect(execution.budget!.takeTool(), isFalse);
      expect(flushed, isTrue);
      expect(request.isCancelled, isTrue);
      expect(execution.isCancelled, isFalse);
      final finalRequest = CancelToken();
      execution.attachRequest(finalRequest);
      execution.releaseRequest(request);
      expect(execution.budget!.finishing, isTrue);
      execution.cancel();
      expect(finalRequest.isCancelled, isTrue);
    },
  );

  test('dispose cancels a hanging stream and releases both waiters', () async {
    final execution = GenerationExecution()..tryStart();
    final source = StreamController<String>();
    final request = CancelToken();
    execution.attachRequest(request);
    final consumed = execution.consumeStream(
      source.stream,
      cancelToken: request,
      onData: (_) {},
    );
    final idle = execution.whenIdle;
    execution.dispose();
    await Future.wait([consumed, idle]);
    expect(source.hasListener, isFalse);
    expect(request.isCancelled, isTrue);
    expect(execution.tryStart(), isFalse);
    await source.close();
  });

  test(
    'tool batch returns every call id while enforcing both limits',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      execution.beginBudget(
        const TaskBudgetPrefs(maxToolCalls: 2),
        beforeCancel: () {},
      );
      final runner = ToolCallRunner(execution);
      final executed = <String>[];
      Future<List<LlmRequestMessage>> run(List<String> ids, int maxCalls) =>
          runner.run(
            calls: ids.map(_call).toList(),
            maxCalls: maxCalls,
            cancelToken: CancelToken(),
            execute: (call) {
              expect(execution.isExecutingTool, isTrue);
              executed.add(call.id!);
              return 'done ${call.id}';
            },
          );
      final first = await run(['a', 'b'], 1);
      expect(first.map((r) => r.toolCallId), ['a', 'b']);
      expect(first.last.content, contains('已跳过'));
      final second = await run(['c', 'd'], 2);
      expect(executed, ['a', 'c']);
      expect(second.last.content, contains('工具调用次数已达上限'));
      expect(execution.isExecutingTool, isFalse);
    },
  );

  test(
    'cancel during a tool preserves its result and skips later side effects',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      final entered = Completer<void>();
      final release = Completer<String>();
      final executed = <String>[];
      final token = CancelToken();
      execution.attachRequest(token);
      final running = ToolCallRunner(execution).run(
        calls: [_call('first'), _call('second')],
        maxCalls: 4,
        cancelToken: token,
        execute: (call) {
          executed.add(call.id!);
          entered.complete();
          return release.future;
        },
      );
      await entered.future;
      execution.cancel();
      release.complete('completed before remote cancellation');
      final replies = await running;
      expect(executed, ['first']);
      expect(replies.first.content, 'completed before remote cancellation');
      expect(replies.last.content, contains('未执行'));
      expect(execution.isExecutingTool, isFalse);
    },
  );

  test(
    'a failing tool becomes an unknown-outcome reply and skips the rest of its batch',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      var calls = 0;
      final replies = await ToolCallRunner(execution).run(
        calls: [_call('a'), _call('b')],
        maxCalls: 4,
        cancelToken: CancelToken(),
        execute: (_) {
          calls++;
          throw StateError('failed');
        },
      );
      expect(calls, 1);
      expect(replies.map((r) => r.toolCallId), ['a', 'b']);
      final first = jsonDecode(replies.first.content) as Map;
      expect(first['ok'], isFalse);
      expect(first['execution_outcome'], 'unknown');
      expect(first['error'], contains('failed'));
      expect(replies.last.content, startsWith('未执行：'));
      expect(execution.isExecutingTool, isFalse);
    },
  );

  test(
    'consecutive concurrent calls overlap; replies and results keep request order',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      final gates = {
        for (final id in ['r1', 'r2', 'r3']) id: Completer<void>(),
      };
      final events = <String>[];
      var inFlight = 0, maxInFlight = 0;
      final running = ToolCallRunner(execution).run(
        calls: [_call('r1'), _call('r2'), _call('w'), _call('r3')],
        cancelToken: CancelToken(),
        concurrent: (call) => call.id!.startsWith('r'),
        onResult: (call, _) => events.add('result:${call.id}'),
        execute: (call) async {
          inFlight++;
          maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
          events.add('start:${call.id}');
          await gates[call.id]?.future;
          inFlight--;
          return 'done ${call.id}';
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, ['start:r1', 'start:r2']);
      gates['r2']!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains('start:w')));
      gates['r1']!.complete();
      await Future<void>.delayed(Duration.zero);
      gates['r3']!.complete();
      final replies = await running;
      expect(maxInFlight, 2);
      expect(replies.map((r) => r.toolCallId), ['r1', 'r2', 'w', 'r3']);
      expect(replies.map((r) => r.content), [
        'done r1',
        'done r2',
        'done w',
        'done r3',
      ]);
      expect(events, [
        'start:r1',
        'start:r2',
        'result:r1',
        'result:r2',
        'start:w',
        'result:w',
        'start:r3',
        'result:r3',
      ]);
    },
  );

  test('cancellation inside a tool still propagates', () async {
    final execution = GenerationExecution()..tryStart();
    addTearDown(execution.dispose);
    final token = CancelToken();
    await expectLater(
      ToolCallRunner(execution).run(
        calls: [_call('a')],
        cancelToken: token,
        execute: (_) {
          token.cancel('stop');
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(),
            reason: 'stop',
          );
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(execution.isExecutingTool, isFalse);
  });
}
