import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/work_agent_runtime.dart';

class _Provider implements LlmProvider {
  _Provider(this.respond, {this.onRequest, this.onTools});
  final Stream<ChatChunk> Function(List<LlmRequestMessage>, CancelToken?)
  respond;
  final void Function(LlmConfig config)? onRequest;
  final void Function(List<ToolSpec>? tools)? onTools;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    onRequest?.call(config);
    onTools?.call(tools);
    return respond(messages, cancelToken);
  }
}

WorkAgentEnvironment _environment(LlmProvider provider) => WorkAgentEnvironment(
  provider: provider,
  config: const LlmConfig(
    baseUrl: 'https://test.invalid',
    apiKey: 'test',
    model: 'configured-model',
  ),
  tools: const [],
  executeTool: (_, _, _, _) async => 'approved tool',
  resolveModel: (requested, parent) async =>
      parent.copyWith(model: requested ?? parent.model),
);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Runtime did not reach expected state');
}

void main() {
  test(
    'queued Auto child recovery preserves root quota and gates persistence before dispatch',
    () async {
      var requests = 0;
      final environment = _environment(
        _Provider((_, _) async* {
          requests++;
          yield const ChatChunk(contentDelta: 'resumed', finishReason: 'stop');
        }),
      );
      final source = WorkAgentRuntime();
      final root = source.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: environment,
        limits: const WorkAgentLimits(maxChildren: 1),
      );
      final child = source.spawn(parentId: root, task: 'queued');
      final rows = source.journal();
      source.dispose();
      final blocked = WorkAgentRuntime(
        persistJournal: (_) async => throw StateError('storage failure'),
      );
      addTearDown(blocked.dispose);
      blocked.restoreJournal(rows);
      await expectLater(
        blocked.resumeRestoredChild(
          agentId: child,
          environment: environment,
          reconciliation: 'verified',
          validate: (_) async {},
        ),
        throwsStateError,
      );
      expect(blocked.record(child)!.restored, isTrue);
      expect(requests, 0);
      final restored = WorkAgentRuntime();
      addTearDown(restored.dispose);
      restored.restoreJournal(rows);
      await restored.activateRestoredRoot(
        rootId: root,
        environment: environment,
        validate: (_) async {},
      );
      expect(restored.record(root)!.childrenCreated, 1);
      expect(
        () => restored.spawn(parentId: root, task: 'quota bypass'),
        throwsStateError,
      );
      await restored.resumeRestoredChildUsingRoot(
        agentId: child,
        rootId: root,
        reconciliation: 'verified original root and effects',
        validate: (_) async {},
      );
      await _until(() => restored.record(child)!.terminal);
      expect(restored.record(child)!.status, WorkAgentStatus.completed);
      expect(requests, 1);
    },
  );

  test(
    'failed durable snapshot prevents child model and tool dispatch',
    () async {
      var requests = 0;
      final runtime = WorkAgentRuntime(
        persistJournal: (_) async => throw StateError('storage full'),
      );
      addTearDown(runtime.dispose);
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: _environment(
          _Provider((_, _) async* {
            requests++;
            yield const ChatChunk(
              contentDelta: 'should not run',
              finishReason: 'stop',
            );
          }),
        ),
      );
      final child = runtime.spawn(parentId: root, task: 'child');
      await _until(() => runtime.record(child)!.terminal);
      expect(runtime.record(child)!.status, WorkAgentStatus.failed);
      expect(requests, 0);
      expect(runtime.persistenceError, isA<StateError>());
    },
  );

  test(
    'tool waits release model permits for sibling and root at cap one',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final toolStarted = Completer<void>(), releaseTool = Completer<void>();
      var requests = 0;
      final environment = WorkAgentEnvironment(
        provider: _Provider((_, _) async* {
          requests++;
          if (requests == 1) {
            yield const ChatChunk(
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'wait',
                  name: 'fixture_wait',
                  argumentsJson: '{}',
                ),
              ],
              finishReason: 'tool_calls',
            );
          } else {
            yield const ChatChunk(
              contentDelta: 'completed',
              finishReason: 'stop',
            );
          }
        }),
        config: const LlmConfig(
          baseUrl: 'https://test.invalid',
          apiKey: 'fixture',
          model: 'fixture',
        ),
        tools: const [],
        executeTool: (_, _, _, _) async {
          toolStarted.complete();
          await releaseTool.future;
          return 'done';
        },
        resolveModel: (_, config) async => config,
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: environment,
        limits: const WorkAgentLimits(maxConcurrent: 1),
      );
      final first = runtime.spawn(parentId: root, task: 'first');
      await toolStarted.future;
      expect(runtime.capacity(root)['running_model_requests'], 0);
      final second = runtime.spawn(parentId: root, task: 'second');
      await _until(() => runtime.record(second)!.terminal);
      expect(runtime.record(second)!.status, WorkAgentStatus.completed);
      await runtime.acquireRootSlot(root, CancelToken());
      expect(runtime.capacity(root)['running_model_requests'], 1);
      runtime.releaseRootSlot(root);
      releaseTool.complete();
      await _until(() => runtime.record(first)!.terminal);
      expect(runtime.record(first)!.status, WorkAgentStatus.completed);
    },
  );

  test(
    'journal omits native reasoning and credentials and resumes only after validation',
    () async {
      final runtime = WorkAgentRuntime(), restored = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      addTearDown(restored.dispose);
      final environment = _environment(
        _Provider((_, _) async* {
          yield const ChatChunk(
            contentDelta: 'safe result',
            reasoningDelta: 'HIDDEN_NATIVE_REASONING',
            responseOutputItems: [
              {'secret': 'NATIVE_PAYLOAD'},
            ],
            finishReason: 'stop',
          );
        }),
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: environment,
      );
      final child = runtime.spawn(parentId: root, task: 'task api_key=test');
      await _until(() => runtime.record(child)!.terminal);
      final encoded = jsonEncode(runtime.journal());
      expect(encoded, isNot(contains('HIDDEN_NATIVE_REASONING')));
      expect(encoded, isNot(contains('NATIVE_PAYLOAD')));
      expect(encoded, isNot(contains('api_key=test')));
      restored.restoreJournal(runtime.journal());
      expect(() => restored.followup(child, 'resume'), throwsStateError);
      await expectLater(
        restored.resumeRestoredChild(
          agentId: child,
          environment: environment,
          reconciliation: 'checked',
          validate: (_) async => throw StateError('grant revoked'),
        ),
        throwsStateError,
      );
      expect(restored.record(child)!.restored, isTrue);
      await restored.resumeRestoredChild(
        agentId: child,
        environment: environment,
        reconciliation: 'workspace and side effects checked',
        validate: (_) async {},
      );
      await _until(() => restored.record(child)!.terminal);
      expect(restored.record(child)!.restored, isFalse);
    },
  );

  test(
    'file ownership rejects overlapping siblings and protects root integration',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: _environment(_Provider((_, _) => const Stream.empty())),
      );
      final child = runtime.spawn(
        parentId: root,
        task: 'edit',
        ownedPaths: ['lib/a.dart'],
      );
      expect(
        () => runtime.authorizeFileWrite(child, 'lib/a.dart'),
        returnsNormally,
      );
      expect(
        () => runtime.authorizeFileWrite(child, 'lib/b.dart'),
        throwsStateError,
      );
      expect(
        () => runtime.authorizeFileWrite(root, 'lib/a.dart'),
        throwsStateError,
      );
      expect(
        () => runtime.spawn(
          parentId: root,
          task: 'conflict',
          ownedPaths: ['LIB/a.dart'],
        ),
        throwsStateError,
      );
      final viewer = runtime.spawn(
        parentId: root,
        task: 'read',
        readOnly: true,
      );
      expect(
        () => runtime.authorizeFileWrite(viewer, 'lib/a.dart'),
        throwsStateError,
      );
      expect(
        () =>
            runtime.spawn(parentId: viewer, task: 'escalate', readOnly: false),
        throwsStateError,
      );
      runtime.cancel(child);
      expect(
        () => runtime.authorizeFileWrite(root, 'lib/a.dart'),
        returnsNormally,
      );
      runtime.cancel(root);
    },
  );

  test(
    'root ownership cannot be bypassed by an alias scope and shared child cannot widen root claims',
    () {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: _environment(_Provider((_, _) => const Stream.empty())),
      );
      final child = runtime.spawn(
        parentId: root,
        task: 'web',
        ownedPaths: ['apps/web'],
      );
      final target = jsonEncode({
        'kind': 'local',
        'workspaceId': 'p',
        'root': 'C:/project',
        'scopes': {
          'root': 'C:/project',
          'frontend': 'C:/project/apps/web',
          'outside': 'D:/extra',
        },
      });
      expect(
        () => runtime.authorizeScopedFileWrite(
          root,
          target,
          'frontend',
          'page.dart',
        ),
        throwsStateError,
      );
      expect(
        () => runtime.authorizeScopedFileWrite(
          child,
          target,
          'frontend',
          'apps/web/page.dart',
        ),
        throwsStateError,
      );
      expect(
        () => runtime.authorizeScopedFileWrite(
          child,
          target,
          'root',
          'apps/web/page.dart',
        ),
        returnsNormally,
      );
      expect(
        () => runtime.authorizeScopedFileWrite(
          root,
          target,
          'outside',
          'other.txt',
        ),
        returnsNormally,
      );
      runtime.cancel(child);
      expect(
        () => runtime.authorizeScopedFileWrite(
          root,
          target,
          'frontend',
          'page.dart',
        ),
        returnsNormally,
      );
      runtime.cancel(root);
    },
  );

  test(
    'quota and model-pool refusals are recoverable and advertise remaining capacity',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final response = StreamController<ChatChunk>.broadcast();
      addTearDown(response.close);
      final env = _environment(_Provider((_, _) => response.stream));
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
        limits: const WorkAgentLimits(maxChildren: 1),
      );
      for (final args in [
        {'task': 'write', 'read_only': false},
        {'task': 'bad', 'read_only': 'false'},
        {'task': 'bad', 'isolated': true, 'read_only': true},
      ]) {
        final rejected = jsonDecode(
          await runtime.safeCallTool(root, 'work_spawn_agent', args),
        );
        expect(rejected['ok'], false);
        expect(runtime.record(root)!.childrenCreated, 0);
      }
      final denied = jsonDecode(
        await runtime.safeCallTool(root, 'work_spawn_agent', {
          'task': 'audit',
          'model': 'outside-pool',
        }),
      );
      expect(denied['ok'], false);
      expect(runtime.record(root)!.childrenCreated, 0);
      final created = jsonDecode(
        await runtime.safeCallTool(root, 'work_spawn_agent', {
          'task': 'audit',
          'model': 'configured-model',
        }),
      );
      expect(created['capacity']['children_remaining'], 0);
      final exhausted = jsonDecode(
        await runtime.safeCallTool(root, 'work_spawn_agent', {
          'task': 'another audit',
        }),
      );
      expect(exhausted['ok'], false);
      expect(exhausted['capacity']['children_remaining'], 0);
      expect(runtime.guidanceFor(root), contains('configured-model'));
      final spawnSpec = runtime.toolsFor(root).first.parameters;
      expect((spawnSpec['properties'] as Map)['model']['enum'], [
        'Auto',
        'configured-model',
      ]);
      runtime.cancel(root);
    },
  );

  test(
    'budget exhaustion requests a tool-free summary and persists rounds',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      var requests = 0, toolExecutions = 0;
      final toolLists = <List<ToolSpec>?>[];
      final provider = _Provider((messages, _) async* {
        requests++;
        if (requests <= 2) {
          yield ChatChunk(
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'read-$requests',
                name: 'coding_read_file',
                argumentsJson: '{}',
              ),
            ],
            finishReason: 'tool_calls',
          );
        } else {
          expect(messages.last.content, contains('工具已关闭'));
          yield const ChatChunk(
            contentDelta: '已审查两个文件，剩余范围待继续。',
            finishReason: 'stop',
          );
        }
      }, onTools: toolLists.add);
      final base = _environment(provider);
      final env = WorkAgentEnvironment(
        provider: provider,
        config: base.config,
        tools: const [],
        executeTool: (_, _, _, _) async {
          toolExecutions++;
          return 'file evidence';
        },
        resolveModel: base.resolveModel,
        maxRounds: 2,
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
      );
      final id = runtime.spawn(parentId: root, task: 'audit');
      await _until(() => runtime.record(id)!.terminal);
      expect(toolExecutions, 2);
      expect(requests, 3);
      expect(toolLists.last, isNull);
      expect(runtime.record(id)!.status, WorkAgentStatus.interrupted);
      expect(runtime.record(id)!.output, contains('两个文件'));
      final restored = WorkAgentRuntime();
      addTearDown(restored.dispose);
      restored.restoreJournal(runtime.journal());
      expect(restored.record(id)!.rounds, 3);
    },
  );

  test('an empty final response is not a completed subagent task', () async {
    final runtime = WorkAgentRuntime();
    addTearDown(runtime.dispose);
    final root = runtime.registerRoot(
      conversationId: 'c',
      taskId: 't',
      task: 'root',
      environment: _environment(
        _Provider((_, _) async* {
          yield const ChatChunk(finishReason: 'stop');
        }),
      ),
    );
    final id = runtime.spawn(parentId: root, task: 'audit');
    await _until(() => runtime.record(id)!.terminal);
    expect(runtime.record(id)!.status, WorkAgentStatus.failed);
  });

  test(
    'root usage counts request snapshots once and re-registration retains quota',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final env = _environment(
        _Provider((_, _) async* {
          yield const ChatChunk(contentDelta: 'done', finishReason: 'stop');
        }),
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
      );
      runtime.recordRootRequest(
        root,
        'req',
        config: env.config,
        usage: const LlmUsage(inputTokens: 100, outputTokens: 10),
      );
      runtime.recordRootRequest(
        root,
        'req',
        config: env.config,
        usage: const LlmUsage(inputTokens: 100, outputTokens: 20),
      );
      final child = runtime.spawn(parentId: root, task: 'audit');
      await _until(() => runtime.record(child)!.terminal);
      runtime.finishRoot(root);
      expect(
        runtime.registerRoot(
          conversationId: 'c',
          taskId: 't',
          task: 'event',
          environment: env,
        ),
        root,
      );
      expect(runtime.record(root)!.childrenCreated, 1);
      expect(runtime.record(root)!.rounds, 1);
      expect(runtime.record(root)!.inputTokens, 100);
      expect(runtime.record(root)!.outputTokens, 20);
    },
  );
  test(
    'length termination fails with partial evidence and never executes pending tools',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final events = <WorkAgentEvent>[];
      final subscription = runtime.events.listen(events.add);
      addTearDown(subscription.cancel);
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: _environment(
          _Provider((_, _) async* {
            yield const ChatChunk(contentDelta: 'verified partial evidence');
            yield const ChatChunk(
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'unfinished',
                  name: 'work_spawn_agent',
                  argumentsJson: '{"task":"must not run"}',
                ),
              ],
            );
            yield const ChatChunk(finishReason: 'length');
          }),
        ),
      );
      final id = runtime.spawn(parentId: root, task: 'child');
      await _until(() => runtime.record(id)!.terminal);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.record(id)!.status, WorkAgentStatus.failed);
      expect(runtime.record(id)!.output, contains('verified partial evidence'));
      expect(runtime.record(id)!.output, contains('length'));
      expect(runtime.records, hasLength(2));
      expect(events, hasLength(1));
      expect(events.single.content, contains('failed'));
      expect(events.single.content, contains('verified partial evidence'));
    },
  );

  test(
    'raw DSML envelope is quarantined and fails instead of completing',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: _environment(
          _Provider((_, _) async* {
            yield const ChatChunk(contentDelta: '<|DS');
            yield const ChatChunk(
              contentDelta: 'ML| calls><invoke name="work_spawn_agent">',
            );
            yield const ChatChunk(finishReason: 'stop');
          }),
        ),
      );
      final id = runtime.spawn(parentId: root, task: 'child');
      await _until(() => runtime.record(id)!.terminal);
      expect(runtime.record(id)!.status, WorkAgentStatus.failed);
      expect(runtime.record(id)!.output, contains('DSML'));
      expect(runtime.record(id)!.output, isNot(contains('<invoke')));
      expect(runtime.records, hasLength(2));
    },
  );

  test(
    'followup retains resolved service route and native continuation context',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      var resolutions = 0, requests = 0;
      final routes = <String?>[];
      final provider = _Provider((messages, _) async* {
        requests++;
        if (requests > 1) {
          expect(messages.any((m) => m.responseOutputItems.isNotEmpty), isTrue);
        }
        yield const ChatChunk(
          contentDelta: 'evidence',
          finishReason: 'stop',
          responseOutputItems: [
            {'type': 'message', 'id': 'native-continuation'},
          ],
        );
      }, onRequest: (config) => routes.add(config.routingSessionId));
      final env = WorkAgentEnvironment(
        provider: provider,
        config: const LlmConfig(
          baseUrl: 'https://test.invalid',
          apiKey: 'test',
          model: 'model',
        ),
        tools: const [],
        executeTool: (_, _, _, _) async => 'approved',
        resolveModel: (_, parent) async =>
            parent.copyWith(routingSessionId: 'route-${++resolutions}'),
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
      );
      final id = runtime.spawn(parentId: root, task: 'child');
      await _until(
        () => runtime.record(id)!.status == WorkAgentStatus.completed,
      );
      runtime.followup(id, 'continue with prior evidence');
      await _until(
        () =>
            requests == 2 &&
            runtime.record(id)!.status == WorkAgentStatus.completed,
      );
      expect(resolutions, 1);
      expect(routes, ['route-1', 'route-1']);
    },
  );

  test('cumulative usage chunks are counted once per model request', () async {
    final runtime = WorkAgentRuntime();
    addTearDown(runtime.dispose);
    final env = _environment(
      _Provider((_, _) async* {
        yield const ChatChunk(
          contentDelta: 'partial',
          usage: LlmUsage(
            inputTokens: 10,
            outputTokens: 1,
            cost: .02,
            currency: 'USD',
          ),
        );
        yield const ChatChunk(
          contentDelta: ' result',
          usage: LlmUsage(
            inputTokens: 10,
            outputTokens: 3,
            cost: .05,
            currency: 'USD',
          ),
        );
      }),
    );
    final root = runtime.registerRoot(
      conversationId: 'c',
      taskId: 't',
      task: 'root',
      environment: env,
    );
    final id = runtime.spawn(parentId: root, task: 'child');
    await _until(() => runtime.record(id)!.status == WorkAgentStatus.completed);
    expect(runtime.record(id)!.inputTokens, 10);
    expect(runtime.record(id)!.outputTokens, 3);
    expect(runtime.record(id)!.cost, .05);
  });

  test(
    'depth zero root with depth 2 and cumulative children 3 permits exactly 13 nodes',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final env = _environment(
        _Provider(
          (_, _) => Stream.value(const ChatChunk(contentDelta: 'done')),
        ),
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
        limits: const WorkAgentLimits(
          maxDepth: 2,
          maxChildren: 3,
          maxConcurrent: 1,
        ),
      );
      final children = [
        for (var i = 0; i < 3; i++)
          runtime.spawn(parentId: root, task: 'child $i'),
      ];
      for (final child in children) {
        for (var i = 0; i < 3; i++) {
          final grandchild = runtime.spawn(
            parentId: child,
            task: 'grandchild $i',
          );
          expect(
            () => runtime.spawn(parentId: grandchild, task: 'too deep'),
            throwsStateError,
          );
        }
      }
      expect(runtime.records.length, 13);
      runtime.cancel(children.first);
      expect(
        () => runtime.spawn(parentId: root, task: 'fourth direct child'),
        throwsStateError,
      );
    },
  );

  test(
    'root consumes its task slot and releases it for queued child at cap one',
    () async {
      final entered = Completer<void>(), finish = Completer<void>();
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final env = _environment(
        _Provider((_, token) async* {
          entered.complete();
          await Future.any([finish.future, token!.whenCancel]);
          if (!token.isCancelled) yield const ChatChunk(contentDelta: 'done');
        }),
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
        limits: const WorkAgentLimits(maxConcurrent: 1),
      );
      await runtime.acquireRootSlot(root, CancelToken());
      final child = runtime.spawn(parentId: root, task: 'child');
      await Future<void>.delayed(const Duration(milliseconds: 8));
      expect(entered.isCompleted, isFalse);
      expect(runtime.record(child)!.status, WorkAgentStatus.queued);
      runtime.releaseRootSlot(root);
      await entered.future.timeout(const Duration(seconds: 1));
      finish.complete();
      await _until(() => runtime.record(child)!.terminal);
    },
  );

  test(
    'independent roots do not share concurrency limits or block each other',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final env = _environment(
        _Provider((_, _) async* {
          yield const ChatChunk(contentDelta: 'done');
        }),
      );
      final first = runtime.registerRoot(
        conversationId: 'a',
        taskId: 'a1',
        task: 'first',
        environment: env,
        limits: const WorkAgentLimits(maxConcurrent: 1),
      );
      final second = runtime.registerRoot(
        conversationId: 'b',
        taskId: 'b1',
        task: 'second',
        environment: env,
        limits: const WorkAgentLimits(maxConcurrent: 2),
      );
      await runtime.acquireRootSlot(first, CancelToken());
      final blocked = runtime.spawn(
        parentId: first,
        task: 'must wait for first',
      );
      await runtime
          .acquireRootSlot(second, CancelToken())
          .timeout(const Duration(seconds: 1));
      final free = runtime.spawn(
        parentId: second,
        task: 'can run beside second',
      );
      await _until(() => runtime.record(free)!.terminal);
      expect(runtime.record(blocked)!.status, WorkAgentStatus.queued);
      expect(runtime.capacity(first)['running_model_requests'], 1);
      expect(runtime.capacity(second)['running_model_requests'], 1);
      runtime.releaseRootSlot(first);
      await _until(() => runtime.record(blocked)!.terminal);
      runtime.releaseRootSlot(second);
    },
  );

  test(
    'recursive parent yields its slot then wakes once with child result',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      var parentCalls = 0;
      final env = _environment(
        _Provider((messages, _) async* {
          final parent = messages[1].content == 'parent';
          if (!parent) {
            yield const ChatChunk(contentDelta: 'child evidence');
            return;
          }
          parentCalls++;
          if (parentCalls == 1) {
            yield const ChatChunk(
              toolCalls: [
                ToolCall(
                  index: 0,
                  id: 'spawn',
                  name: 'work_spawn_agent',
                  argumentsJson: '{"task":"child"}',
                ),
              ],
            );
          } else if (parentCalls == 2) {
            yield const ChatChunk(contentDelta: 'waiting for child');
          } else {
            expect(
              messages.any(
                (message) => message.content.contains('child evidence'),
              ),
              isTrue,
            );
            yield const ChatChunk(contentDelta: 'parent consolidated evidence');
          }
        }),
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
        limits: const WorkAgentLimits(maxConcurrent: 1),
      );
      final events = <WorkAgentEvent>[];
      final sub = runtime.events.listen(events.add);
      addTearDown(sub.cancel);
      final parent = runtime.spawn(parentId: root, task: 'parent');
      await _until(
        () => runtime.record(parent)!.status == WorkAgentStatus.completed,
      );
      await Future<void>.delayed(Duration.zero);
      expect(parentCalls, 3);
      expect(events, hasLength(1));
      expect(events.single.content, contains('parent consolidated evidence'));
    },
  );

  test('a child cannot send instructions to a sibling', () async {
    final runtime = WorkAgentRuntime();
    addTearDown(runtime.dispose);
    final env = _environment(
      _Provider((_, _) => Stream.value(const ChatChunk(contentDelta: 'done'))),
    );
    final root = runtime.registerRoot(
      conversationId: 'c',
      taskId: 't',
      task: 'root',
      environment: env,
    );
    final first = runtime.spawn(parentId: root, task: 'first'),
        second = runtime.spawn(parentId: root, task: 'second');
    await expectLater(
      runtime.callTool(first, 'work_followup_agent', {
        'agent_id': second,
        'message': 'bypass',
      }),
      throwsStateError,
    );
  });

  test(
    'journal restores active agents interrupted and refuses automatic replay',
    () async {
      final runtime = WorkAgentRuntime(), restored = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      addTearDown(restored.dispose);
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: _environment(_Provider((_, _) => const Stream.empty())),
      );
      restored.restoreJournal(runtime.journal());
      expect(restored.record(root)!.status, WorkAgentStatus.interrupted);
      expect(() => restored.followup(root, 'resume'), throwsStateError);
    },
  );
}
