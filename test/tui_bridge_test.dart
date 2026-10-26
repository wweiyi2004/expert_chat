import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/features/tui_bridge/discovery.dart';
import 'package:expert_chat/features/tui_bridge/event_diff.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'package:expert_chat/features/tui_bridge/server.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/work_task_steering.dart';
import 'package:expert_chat/state/work_questions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';
import 'package:expert_chat/data/research/ssh_profile.dart';
import 'package:expert_chat/state/research_terminal_controller.dart';
import 'package:expert_chat/state/work_memory.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/state/model_route_groups.dart';
import 'widget_test.dart' show FakeSettings, FakeLlmProvider, InMemoryRepo;

class _TestDiscovery extends BridgeDiscovery {
  _TestDiscovery(super.directory);
  @override
  Future<void> prepare() async {}
  @override
  Future<String> publish(int port) async => 'test-only-secret-token';
  @override
  Future<void> remove() async {}
}

class _Backend implements BridgeBackend {
  int calls = 0;
  String payload = '';
  final opened = <String?>[];
  @override
  List<String> get capabilities => ['message.send'];
  @override
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method != 'message.send') {
      throw const BridgeFailure('unsupported', 'unsupported');
    }
    calls++;
    return {'accepted': true};
  }

  @override
  Future<Map<String, Object?>> snapshot(String? session) async {
    opened.add(session);
    return {
      'session': session == null ? null : {'id': session},
      'startup': {},
      for (final key in [
        'messages',
        'steps',
        'approvals',
        'questions',
        'changes',
        'agents',
        'queued',
        'models',
        'workspaces',
        'sessions',
      ])
        key: key == 'messages' && payload.isNotEmpty
            ? [
                {'id': 'large', 'text': payload},
              ]
            : <Object?>[],
    };
  }
}

class _DelayedHost implements DesktopWorkspaceHost {
  bool enabled = false;
  final entered = Completer<void>();
  final gate = Completer<List<DesktopWorkspace>>();
  @override
  bool get supported => enabled;
  @override
  Future<List<DesktopWorkspace>> list() {
    if (!entered.isCompleted) entered.complete();
    return gate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedLlm extends FakeLlmProvider {
  _GatedLlm(super.chunks);
  Completer<void>? compactGate;
  int transientFailures = 0, httpAttempts = 0;
  final compactEntered = Completer<void>();
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
    httpAttempts++;
    if (transientFailures > 0) {
      transientFailures--;
      throw const LlmHttpException('temporary', statusCode: 503);
    }
    if (config.routingSessionId?.contains('public-checkpoint') == true &&
        compactGate != null) {
      if (!compactEntered.isCompleted) compactEntered.complete();
      await compactGate!.future;
    }
    yield* super.streamChat(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      forceToolName: forceToolName,
      cancelToken: cancelToken,
    );
  }
}

class _ConnectedSsh extends ResearchTerminalController {
  @override
  ResearchTerminalState build() => const ResearchTerminalState(
    profiles: [
      SshProfile(
        id: 'ssh-test',
        name: 'test',
        host: 'invalid.test',
        username: 'test',
      ),
    ],
    activeProfileId: 'ssh-test',
    status: ResearchConnectionStatus.connected,
  );
}

Future<Map<String, dynamic>> _reply(
  StreamIterator<dynamic> messages,
  String id,
) async {
  while (await messages.moveNext().timeout(const Duration(seconds: 10))) {
    final message =
        jsonDecode(messages.current as String) as Map<String, dynamic>;
    if (message['id'] == id) return message;
  }
  throw StateError('socket closed');
}

void _request(
  WebSocket socket,
  String id,
  String method, [
  Map<String, Object?> params = const {},
]) => socket.add(
  jsonEncode({'v': 1, 'id': id, 'method': method, 'params': params}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('loopback transport', () {
    late TuiBridgeServer server;
    late _Backend backend;
    setUp(() async {
      backend = _Backend();
      server = TuiBridgeServer(
        backend: backend,
        discovery: _TestDiscovery(Directory.systemTemp),
      );
      await server.start();
    });
    tearDown(() => server.stop());
    Future<(WebSocket, StreamIterator<dynamic>)> connect() async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/tui',
      );
      final messages = StreamIterator(socket);
      _request(socket, 'hello', 'hello', {
        'protocol': 1,
        'token': 'test-only-secret-token',
        'client_id': 'test-client',
      });
      expect((await _reply(messages, 'hello'))['ok'], true);
      return (socket, messages);
    }

    test('unauthenticated cannot query and wrong token closes', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/tui',
      );
      final messages = StreamIterator(socket);
      _request(socket, 'private', 'snapshot.get');
      final reply = await _reply(messages, 'private');
      expect(reply['ok'], false);
      expect(backend.opened, isEmpty);
      expect(await messages.moveNext(), false);
    });
    test(
      'rejects Origin and wrong endpoint before websocket upgrade',
      () async {
        await expectLater(
          WebSocket.connect(
            'ws://127.0.0.1:${server.port}/tui',
            headers: {'Origin': 'http://localhost'},
          ),
          throwsA(isA<WebSocketException>()),
        );
        await expectLater(
          WebSocket.connect('ws://127.0.0.1:${server.port}/other'),
          throwsA(isA<WebSocketException>()),
        );
      },
    );
    test(
      'dedup reconnect, id conflict, explicit subscription and disconnect leaves backend',
      () async {
        final (one, messages) = await connect();
        _request(one, 'send', 'message.send', {
          'session_id': 'a',
          'text': 'once',
        });
        expect((await _reply(messages, 'send'))['ok'], true);
        _request(one, 'send', 'message.send', {
          'session_id': 'a',
          'text': 'once',
        });
        await _reply(messages, 'send');
        expect(backend.calls, 1);
        _request(one, 'send', 'message.send', {
          'session_id': 'b',
          'text': 'changed',
        });
        expect(
          ((await _reply(messages, 'send'))['error'] as Map)['code'],
          'conflict',
        );
        _request(one, 'open', 'session.open', {'session_id': 'a'});
        expect(((await _reply(messages, 'open'))['result'] as Map)['session'], {
          'id': 'a',
        });
        await one.close();
        await messages.cancel();
        final (two, second) = await connect();
        _request(two, 'send', 'message.send', {
          'session_id': 'a',
          'text': 'once',
        });
        await _reply(second, 'send');
        expect(backend.calls, 1);
        _request(two, 'snapshot', 'snapshot.get', {'session_id': 'b'});
        expect(
          ((await _reply(second, 'snapshot'))['result'] as Map)['session'],
          {'id': 'b'},
        );
        await two.close();
        await second.cancel();
        expect(backend.calls, 1);
      },
    );
    test('request size is enforced', () async {
      final (socket, messages) = await connect();
      socket.add('x' * (1024 * 1024 + 1));
      while (await messages.moveNext()) {}
      expect(socket.closeCode, WebSocketStatus.messageTooBig);
      expect(backend.calls, 0);
    });
    test('snapshot limit returns an explicit failure', () async {
      final (socket, messages) = await connect();
      backend.payload = 'x' * (8 * 1024 * 1024);
      _request(socket, 'large', 'snapshot.get');
      final response = await _reply(messages, 'large');
      expect(response['ok'], false);
      expect((response['error'] as Map)['code'], 'too_large');
      await socket.close();
      await messages.cancel();
    });
    test(
      'silent unauthenticated connection expires after five seconds',
      () async {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${server.port}/tui',
        );
        await socket.drain<void>().timeout(const Duration(seconds: 8));
        expect(socket.closeCode, WebSocketStatus.policyViolation);
        expect(backend.opened, isEmpty);
      },
    );
    test('version mismatch rejected without backend access', () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${server.port}/tui',
      );
      final messages = StreamIterator(socket);
      socket.add(
        jsonEncode({'v': 2, 'id': 'old', 'method': 'hello', 'params': {}}),
      );
      expect(
        ((await _reply(messages, 'old'))['error'] as Map)['code'],
        'version',
      );
      expect(backend.calls, 0);
      await socket.close();
      await messages.cancel();
    });
  });

  test(
    'shared fixtures conform to schema event and snapshot required fields',
    () {
      final schema =
          jsonDecode(File('design/tui/protocol.schema.json').readAsStringSync())
              as Map;
      final definitions = schema[r'$defs'] as Map;
      final events =
          ((definitions['event'] as Map)['properties'] as Map)['event']['enum']
              as List;
      final required = (definitions['snapshot'] as Map)['required'] as List;
      for (final file in Directory(
        'design/tui/fixtures',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) {
        var seq = 0;
        for (final line
            in const LineSplitter()
                .convert(file.readAsStringSync())
                .where((s) => s.trim().isNotEmpty)) {
          final event = jsonDecode(line) as Map;
          expect(event['v'], 1);
          expect(event['type'], 'event');
          expect(events, contains(event['event']));
          expect(event['seq'], greaterThan(seq));
          seq = event['seq'] as int;
          if (event['event'] == 'snapshot') {
            expect((event['data'] as Map).keys, containsAll(required));
          }
        }
      }
    },
  );
  test(
    'event derivation uses factual public suffixes and no fabricated retries',
    () {
      final before = <String, Object?>{
        'session': {'id': 's', 'status': 'running', 'round': 1},
        'messages': [
          {'id': 'm', 'role': 'assistant', 'text': 'a'},
        ],
      };
      final after = <String, Object?>{
        'session': {'id': 's', 'status': 'idle', 'round': 1},
        'messages': [
          {'id': 'm', 'role': 'assistant', 'text': 'abc'},
        ],
      };
      final events = bridgeSnapshotEvents(before, after);
      expect(
        events.where((e) => e.event == 'assistant.delta').single.data['text'],
        'bc',
      );
      expect(events.any((e) => e.event == 'request.retry'), false);
    },
  );
  test(
    'secret redaction traverses text, tools, arguments, diff and nested fields',
    () {
      final data = {
        'messages': [
          {'text': 'private-secret'},
        ],
        'diff': ['+private-secret'],
        'arguments': 'Bearer abcdefghijklmnopqrstuvwxyz',
      };
      final redacted = jsonEncode(redactBridgeValue(data, ['private-secret']));
      expect(redacted, isNot(contains('private-secret')));
      expect(redacted, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    },
  );
  test(
    'exact operation session grant is canonical, target scoped, revocable and denies with reason',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final approvals = container.read(workApprovalsProvider.notifier);
      final request = PendingWorkApproval(
        id: 'one',
        conversationId: 'a',
        tool: 'shell',
        arguments: '{"b":2,"a":1}',
        target: 'host',
        reason: '',
      );
      final pending = approvals.ask(request, CancelToken());
      expect(
        () => approvals.decideScoped('b', 'one', 'session'),
        throwsStateError,
      );
      approvals.decideScoped('a', 'one', 'session');
      expect(await pending, true);
      expect(approvals.isAllowed('a', 'shell', '{"a":1,"b":2}', 'host'), true);
      expect(approvals.isAllowed('a', 'shell', '{"a":1}', 'host'), false);
      expect(approvals.isAllowed('b', 'shell', '{"a":1,"b":2}', 'host'), false);
      expect(
        approvals.isAllowed('a', 'shell', '{"a":1,"b":2}', 'other'),
        false,
      );
      approvals.revokeSession('a');
      expect(approvals.isAllowed('a', 'shell', '{"a":1,"b":2}', 'host'), false);
      final denial = PendingWorkApproval(
        id: 'two',
        conversationId: 'a',
        tool: 'shell',
        arguments: '{}',
        target: 'host',
        reason: '',
      );
      final rejected = approvals.ask(denial, CancelToken());
      approvals.decideScoped('a', 'two', 'reject_reason', reason: 'keep data');
      expect(await rejected, false);
      expect(approvals.takeDenial('a', 'shell', '{}', 'host'), 'keep data');
    },
  );
  test(
    'withdraw is serialized with prepare and failed persistence retains queue',
    () async {
      final disk = <String, String>{};
      var writable = true;
      final store = TaskSteeringStore(
        read: (k) => disk[k],
        write: (k, v) async {
          if (writable) disk[k] = v;
          return writable;
        },
      );
      final a = await store.enqueue('s', 't', 'first');
      final b = await store.enqueue('s', 't', 'second');
      writable = false;
      await expectLater(
        store.withdraw('s', a['id'] as String),
        throwsStateError,
      );
      expect(store.snapshot('s').first['status'], 'queued');
      writable = true;
      expect(await store.withdraw('s', a['id'] as String), 'first');
      final prepared = await store.prepare('s', 't', 1);
      expect(prepared.single['id'], b['id']);
      await expectLater(
        store.withdraw('s', b['id'] as String),
        throwsStateError,
      );
    },
  );
  group('real shared controller without paid models', () {
    late ProviderContainer container;
    late AppDatabase db;
    late InMemoryRepo repo;
    late _GatedLlm llm;
    late ControllerBridgeBackend backend;
    late _DelayedHost host;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      db = AppDatabase(NativeDatabase.memory());
      repo = InMemoryRepo();
      llm = _GatedLlm([
        const ChatChunk(contentDelta: 'done', finishReason: 'stop'),
      ]);
      host = _DelayedHost();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(repo),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          desktopWorkspaceHostProvider.overrideWithValue(host),
          llmProvider.overrideWithValue(llm),
          researchTerminalProvider.overrideWith(_ConnectedSsh.new),
        ],
      );
      await container.read(chatControllerProvider.future);
      backend = ControllerBridgeBackend(container);
    });
    tearDown(() async {
      container.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.close();
    });
    test(
      'new session accepts selected connected SSH workspace identity',
      () async {
        final listed =
            (await backend.invoke('workspace.list', {}))['workspaces'] as List;
        final ssh =
            (listed.firstWhere((w) => (w as Map)['remote'] == true)
                as Map)['id'];
        final id =
            (await backend.invoke('session.new', {
                  'workspace_id': ssh,
                }))['session_id']
                as String;
        expect(
          container.read(sessionPolicyProvider)[id]!.sshProfileId,
          'ssh-test',
        );
        expect(
          ((await backend.snapshot(id))['session'] as Map)['workspace_id'],
          ssh,
        );
        await expectLater(
          backend.invoke('session.new', {'workspace_id': 'ssh:missing'}),
          throwsA(isA<BridgeFailure>()),
        );
      },
    );
    test(
      'snapshot associates only exact approval, preserves interruption rounds and timing',
      () async {
        final user = ChatMessage(role: MessageRole.user, content: 'task');
        final assistant = ChatMessage(
          role: MessageRole.assistant,
          parentId: user.id,
          content: 'partial',
          reasoning: 'public reasoning',
          thinkingMillis: 1234,
          searchActivities: [
            SearchActivity(
              id: 'blocked',
              kind: SearchActivityKind.mcp,
              query: 'write',
              toolName: 'coding_write_file',
              toolCallId: 'call-a',
              roundId: 'round-1',
            ),
            SearchActivity(
              id: 'live',
              kind: SearchActivityKind.mcp,
              query: 'read',
              toolName: 'coding_read_file',
              toolCallId: 'call-b',
              roundId: 'round-2',
            ),
            SearchActivity(
              id: 'stopped',
              kind: SearchActivityKind.mcp,
              query: 'stop',
              status: SearchActivityStatus.failed,
              interrupted: true,
              roundId: 'round-2',
            ),
            SearchActivity(
              id: 'failed',
              kind: SearchActivityKind.mcp,
              query: 'fail',
              status: SearchActivityStatus.failed,
              roundId: 'round-1',
            ),
          ],
        );
        final conversation = Conversation(
          workMode: true,
          messages: [user, assistant],
          activeChildren: {kRootKey: user.id, user.id: assistant.id},
        );
        repo.store = [conversation];
        container.invalidate(chatControllerProvider);
        await container.read(chatControllerProvider.future);
        final token = CancelToken();
        final pending = container
            .read(workApprovalsProvider.notifier)
            .ask(
              PendingWorkApproval(
                id: 'approval',
                conversationId: conversation.id,
                toolCallId: 'call-a',
                tool: 'coding_write_file',
                arguments: '{}',
                target: 'test',
                reason: 'test',
              ),
              token,
            );
        final snapshot = await backend.snapshot(conversation.id);
        final steps = {
          for (final a in snapshot['steps'] as List) (a as Map)['id']: a,
        };
        expect(steps['blocked']!['status'], 'approval');
        expect(steps['live']!['status'], 'running');
        expect(steps['stopped']!['status'], 'stopped');
        expect(steps['failed']!['status'], 'failed');
        expect(steps['blocked']!['round_id'], 'round-1');
        expect(steps['live']!['round_id'], 'round-2');
        expect(
          (snapshot['messages'] as List).last['thinking_elapsed_ms'],
          1234,
        );
        token.cancel();
        await pending;
        final restored = SearchActivity.fromJson(
          assistant.searchActivities[2].toJson(),
        );
        expect(restored.interrupted, true);
        expect(restored.roundId, 'round-2');
      },
    );
    test(
      'model group and auto choices have readable snapshot labels',
      () async {
        final id =
            (await backend.invoke('session.new', {}))['session_id'] as String;
        await container.read(modelRouteGroupsProvider.notifier).save([
          const ModelRouteGroup(
            id: 'g',
            name: 'Review models',
            models: ['deepseek-chat'],
          ),
        ]);
        await container
            .read(conversationModelChoiceProvider.notifier)
            .select(id, '${modelGroupPrefix}g');
        expect(
          ((await backend.snapshot(id))['session'] as Map)['model'],
          'Review models',
        );
        await container
            .read(conversationModelChoiceProvider.notifier)
            .select(id, autoModelChoice);
        expect(
          ((await backend.snapshot(id))['session'] as Map)['model'],
          '自动选择',
        );
      },
    );
    test(
      'context.compact saves real public checkpoint and preserves original messages',
      () async {
        final controller = container.read(chatControllerProvider.notifier);
        final id = await controller.createWorkSession();
        await controller.sendToSession(id, 'Preserve the original goal');
        final before = container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .firstWhere((c) => c.id == id)
            .activePath
            .map((m) => m.content)
            .toList();
        llm.chunks
          ..clear()
          ..add(
            const ChatChunk(
              contentDelta:
                  '{"summary":"Verified public result","constraints":"Preserve goal","plan":"Review","open_questions":[]}',
              finishReason: 'stop',
            ),
          );
        final result = await backend.invoke('context.compact', {
          'session_id': id,
        });
        expect(result['accepted'], true);
        expect((result['result'] as Map)['summary'], 'Verified public result');
        expect(
          container.read(workMemoryProvider).snapshot(id)['compact_revision'],
          greaterThan(0),
        );
        expect(
          container
              .read(chatControllerProvider)
              .requireValue
              .conversations
              .firstWhere((c) => c.id == id)
              .activePath
              .map((m) => m.content)
              .toList(),
          before,
        );
        expect(llm.lastThinking, false);
        expect(llm.lastTools, isNull);
        final empty = await controller.createWorkSession();
        await expectLater(
          backend.invoke('context.compact', {'session_id': empty}),
          throwsA(isA<StateError>()),
        );
      },
    );
    test(
      'context compaction busy guard blocks new messages and task.stop cancels',
      () async {
        final controller = container.read(chatControllerProvider.notifier);
        final id = await controller.createWorkSession();
        await controller.sendToSession(id, 'Keep this original goal');
        llm.compactGate = Completer<void>();
        final pending = expectLater(
          backend.invoke('context.compact', {'session_id': id}),
          throwsA(anything),
        );
        await llm.compactEntered.future;
        await expectLater(
          backend.invoke('context.compact', {'session_id': id}),
          throwsA(isA<BridgeFailure>().having((e) => e.code, 'code', 'busy')),
        );
        expect(await controller.sendToSession(id, 'must not start'), false);
        await backend.invoke('task.stop', {'session_id': id});
        await pending;
        llm.compactGate!.complete();
        expect(controller.isContextCompacting(id), false);
        expect(
          container.read(workMemoryProvider).snapshot(id)['compact_revision'],
          isNull,
        );
      },
    );
    test(
      'real controller publishes actual retry countdown and counts actual HTTP attempts',
      () async {
        final controller = container.read(chatControllerProvider.notifier);
        final id = await controller.createWorkSession();
        llm.transientFailures = 1;
        final done = controller.sendToSession(
          id,
          'Retry only before any result',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 4));
        while (controller.retryForSession(id)?['active'] != true) {
          if (DateTime.now().isAfter(deadline)) fail('missing retry');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final snapshot = await backend.snapshot(id);
        final session = snapshot['session'] as Map;
        expect(session['status'], 'retrying');
        final runningBefore = Map<String, Object?>.from(snapshot)
          ..['session'] = {...session, 'status': 'running', 'retry': null};
        expect(
          bridgeSnapshotEvents(
            runningBefore,
            snapshot,
          ).any((e) => e.event == 'round.ended'),
          false,
        );
        expect(session['retry']['attempt'], 2);
        expect(session['retry']['retry_after_ms'], greaterThan(0));
        await done;
        expect(llm.httpAttempts, 2);
        expect(controller.retryForSession(id)?['active'], false);
        final finished = await backend.snapshot(id);
        expect((finished['session'] as Map)['request_count'], 2);
        final before = Map<String, Object?>.from(snapshot)
          ..['session'] = {...session, 'retry': null};
        expect(
          bridgeSnapshotEvents(
            before,
            snapshot,
          ).any((e) => e.event == 'request.retry'),
          true,
        );
      },
    );
    test(
      'fresh terminal thinking is high enabled and remains adjustable',
      () async {
        final controller = container.read(chatControllerProvider.notifier);
        final gui = await controller.createWorkSession(title: 'GUI');
        await controller.selectConversation(gui);
        controller.toggleDeepThink();
        controller.setReasoningEffort(ReasoningEffort.low);
        final terminal = await controller.createWorkSession(title: 'TUI');
        expect(controller.thinkingForSession(terminal), true);
        expect(controller.effortForSession(terminal), ReasoningEffort.high);
        expect(await controller.sendToSession(terminal, 'first'), true);
        expect(llm.lastThinking, true);
        expect(llm.lastReasoningEffort, ReasoningEffort.high);
        expect(
          container.read(chatControllerProvider).requireValue.currentId,
          gui,
        );
        expect(
          container.read(chatControllerProvider).requireValue.deepThink,
          false,
        );
        controller.configureSessionThinking(
          terminal,
          false,
          ReasoningEffort.low,
        );
        expect(await controller.sendToSession(terminal, 'second'), true);
        expect(llm.lastThinking, false);
        expect(llm.lastReasoningEffort, isNull);
        expect(controller.effortForSession(terminal), ReasoningEffort.low);
        controller.configureSessionThinking(
          terminal,
          true,
          ReasoningEffort.low,
        );
        expect(await controller.sendToSession(terminal, 'third'), true);
        expect(llm.lastThinking, true);
        expect(llm.lastReasoningEffort, ReasoningEffort.low);
      },
    );

    test(
      'new session persists itself and explicit send never follows GUI selection',
      () async {
        final controller = container.read(chatControllerProvider.notifier);
        final a =
            (await backend.invoke('session.new', {
                  'title': '[TUI测试] a',
                }))['session_id']
                as String;
        final b =
            (await backend.invoke('session.new', {
                  'title': '[TUI测试] b',
                }))['session_id']
                as String;
        await controller.selectConversation(b);
        expect(repo.store.any((c) => c.id == a), true);
        expect(await controller.sendToSession(a, 'only a'), true);
        final state = container.read(chatControllerProvider).requireValue;
        expect(state.currentId, b);
        expect(
          state.conversations
              .firstWhere((c) => c.id == a)
              .activePath
              .any((m) => m.content == 'only a'),
          true,
        );
        expect(
          state.conversations.firstWhere((c) => c.id == b).messages,
          isEmpty,
        );
        final snapshot = await backend.snapshot(a);
        expect((snapshot['session'] as Map)['id'], a);
        final catalog = snapshot['sessions'] as List;
        expect(
          (catalog.firstWhere((row) => (row as Map)['id'] == a)
              as Map)['empty'],
          false,
        );
        expect(
          (catalog.firstWhere((row) => (row as Map)['id'] == b)
              as Map)['empty'],
          true,
        );
        expect(jsonEncode(snapshot), isNot(contains('gateway-token')));
        expect(jsonEncode(snapshot), isNot(contains('search-key')));
      },
    );
    test(
      'full requires second confirmation and plan policy persists with legacy default',
      () async {
        final id =
            (await backend.invoke('session.new', {}))['session_id'] as String;
        await expectLater(
          backend.invoke('permission.set', {
            'session_id': id,
            'permission': 'full',
          }),
          throwsA(isA<BridgeFailure>()),
        );
        expect(container.read(sessionPolicyProvider)[id]?.approval, isNull);
        await backend.invoke('mode.set', {'session_id': id, 'mode': 'plan'});
        expect(container.read(sessionPolicyProvider)[id]!.planOnly, true);
        expect(SessionPolicy.fromJson({}).planOnly, false);
        expect(
          SessionPolicy.fromJson(
            container.read(sessionPolicyProvider)[id]!.toJson(),
          ).planOnly,
          true,
        );
      },
    );
    test('metadata awaits cannot publish a stale controller session', () async {
      final id =
          (await backend.invoke('session.new', {
                'title': 'before',
              }))['session_id']
              as String;
      host.enabled = true;
      final pending = backend.snapshot(id);
      await host.entered.future;
      container
          .read(chatControllerProvider.notifier)
          .renameConversation(id, 'after');
      host.gate.complete([]);
      expect(((await pending)['session'] as Map)['title'], 'after');
    });
    test(
      'questions validate required answers and reject another session id',
      () async {
        final id =
            (await backend.invoke('session.new', {}))['session_id'] as String;
        final other =
            (await backend.invoke('session.new', {}))['session_id'] as String;
        final pending = container
            .read(workQuestionsProvider.notifier)
            .ask(
              PendingWorkQuestion(
                id: 'question',
                conversationId: id,
                assistantId: 'assistant',
                questions: WorkQuestion.parse({
                  'questions': [
                    {
                      'id': 'q',
                      'question': '选择一项',
                      'options': ['one', 'two'],
                      'required': true,
                    },
                  ],
                }),
              ),
              CancelToken(),
            );
        await expectLater(
          backend.invoke('question.answer', {
            'session_id': other,
            'id': 'question',
            'answers': {},
          }),
          throwsA(isA<BridgeFailure>()),
        );
        await expectLater(
          backend.invoke('question.answer', {
            'session_id': id,
            'id': 'question',
            'answers': {
              'q': {'selected': [], 'text': ''},
            },
          }),
          throwsStateError,
        );
        await backend.invoke('question.answer', {
          'session_id': id,
          'id': 'question',
          'answers': {
            'q': {
              'selected': ['one'],
              'text': '',
            },
          },
        });
        expect(((await pending)['answers'] as Map)['q'], {
          'selected': ['one'],
          'text': '',
        });
      },
    );
  });
}
