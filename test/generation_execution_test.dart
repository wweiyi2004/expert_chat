import 'dart:async';

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
    'a failing tool unwinds execution state and does not run later calls',
    () async {
      final execution = GenerationExecution()..tryStart();
      addTearDown(execution.dispose);
      var calls = 0;
      await expectLater(
        ToolCallRunner(execution).run(
          calls: [_call('a'), _call('b')],
          maxCalls: 4,
          cancelToken: CancelToken(),
          execute: (_) {
            calls++;
            throw StateError('failed');
          },
        ),
        throwsStateError,
      );
      expect(calls, 1);
      expect(execution.isExecutingTool, isFalse);
    },
  );
}
