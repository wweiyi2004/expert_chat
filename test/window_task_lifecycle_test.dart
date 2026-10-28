import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/task_window.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/tui_bridge/discovery.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'package:expert_chat/features/tui_bridge/server.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/task_plans.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Model implements LlmProvider {
  final tokens = <String, CancelToken>{};
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
    final text = messages.lastWhere((m) => m.role == MessageRole.user).content;
    tokens[text] = cancelToken!;
    yield const ChatChunk(contentDelta: 'started');
    if (text != 'complete') await cancelToken.whenCancel;
    yield const ChatChunk(finishReason: 'stop');
  }
}

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition not reached');
}

class _Discovery extends BridgeDiscovery {
  _Discovery() : super(Directory.systemTemp);
  @override
  Future<String> publish(int port) async => 'window-test-token';
  @override
  Future<void> remove() async {}
}

class _Backend
    implements BridgeBackend, BridgeClientLifecycle, WindowTaskLifecycle {
  final registered = <String>[];
  final released = <String>[];
  @override
  List<String> get capabilities => [];
  @override
  void registerWindowClient(String scope) => registered.add(scope);
  @override
  Future<Map<String, Object?>> snapshotForWindow(
    String scope,
    String? session,
  ) => snapshot(session);
  @override
  Future<void> releaseClient(String scope) async {
    released.add(scope);
  }

  @override
  Future<void> selectClientSession(String scope, String session) async {}
  @override
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> params,
  ) async => {};
  @override
  Future<Map<String, Object?>> snapshot(String? session) async => {};
}

class _Peer {
  _Peer(this.socket) : input = StreamIterator(socket);
  final WebSocket socket;
  final StreamIterator input;
  int sequence = 0;
  Future<Map> call(String method, Map params) async {
    final id = '${++sequence}';
    socket.add(
      jsonEncode({'v': 1, 'id': id, 'method': method, 'params': params}),
    );
    while (await input.moveNext()) {
      final value = jsonDecode(input.current as String) as Map;
      if (value['id'] == id) return value;
    }
    throw StateError('socket closed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late AppDatabase db;
  late _Model model;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    model = _Model();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        settingsControllerProvider.overrideWith(FakeSettings.new),
        desktopWorkspaceHostProvider.overrideWithValue(
          stub.createDesktopWorkspaceHost(),
        ),
        llmProvider.overrideWithValue(model),
      ],
    );
    await container.read(chatControllerProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'closing a window cancels its work without cancelling another window',
    () async {
      final ctrl = container.read(chatControllerProvider.notifier);
      ctrl.newConversation(workMode: true, forceNew: true);
      final a = container.read(chatControllerProvider).requireValue.currentId!;
      ctrl.newConversation(workMode: true, forceNew: true);
      final b = container.read(chatControllerProvider).requireValue.currentId!;
      final ownerA = TaskWindow('a'), ownerB = TaskWindow('b');
      final first = ownerA.run(() => ctrl.sendToSession(a, 'A'));
      final second = ownerB.run(() => ctrl.sendToSession(b, 'B'));
      await until(() => model.tokens.length == 2);
      await ctrl.stopWindowTasks(ownerA);
      expect(model.tokens['A']!.isCancelled, true);
      expect(model.tokens['B']!.isCancelled, false);
      expect(ctrl.isConversationRunning(b), true);
      await ctrl.stopWindowTasks(ownerB);
      await Future.wait([first, second]);
    },
  );

  test('a closed window cannot start a delayed request', () async {
    final ctrl = container.read(chatControllerProvider.notifier);
    ctrl.newConversation(workMode: true, forceNew: true);
    final id = container.read(chatControllerProvider).requireValue.currentId!;
    final owner = TaskWindow('closed'), gate = Completer<void>();
    final late = owner.run(() async {
      await gate.future;
      return ctrl.sendToSession(id, 'late');
    });
    await ctrl.stopWindowTasks(owner);
    gate.complete();
    expect(await late, false);
    expect(model.tokens, isEmpty);
  });

  test('closing a window cancels its pending plan review', () async {
    final ctrl = container.read(chatControllerProvider.notifier);
    ctrl.newConversation(workMode: true, forceNew: true);
    final id = container.read(chatControllerProvider).requireValue.currentId!;
    await container
        .read(sessionPolicyProvider.notifier)
        .save(id, const SessionPolicy(planOnly: true));
    final window = TaskWindow('plan');
    final request = window.run(() => ctrl.sendToSession(id, 'complete'));
    await until(
      () =>
          container.read(taskPlansProvider)[id]?.status.name ==
          'awaitingApproval',
    );
    await ctrl.stopWindowTasks(window);
    await request;
    expect(ctrl.isConversationRunning(id), false);
    expect(container.read(taskPlansProvider)[id]?.status.name, 'cancelled');
    expect(
      container
          .read(chatControllerProvider)
          .requireValue
          .sessionCheckpoints[id]
          ?.status,
      SessionExecutionStatus.cancelled,
    );
  });

  test(
    'a later task in the same conversation belongs to its new window',
    () async {
      final ctrl = container.read(chatControllerProvider.notifier);
      ctrl.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final a = TaskWindow('a'), b = TaskWindow('b');
      await a.run(() => ctrl.sendToSession(id, 'complete'));
      final active = b.run(() => ctrl.sendToSession(id, 'B'));
      await until(() => model.tokens.containsKey('B'));
      await ctrl.stopWindowTasks(a);
      expect(model.tokens['B']!.isCancelled, false);
      await ctrl.stopWindowTasks(b);
      await active;
    },
  );

  test(
    'a quick reconnect keeps window ownership, explicit close releases it',
    () async {
      final backend = _Backend();
      final server = TuiBridgeServer(backend: backend, discovery: _Discovery());
      await server.start();
      _Peer? peer;
      try {
        peer = _Peer(
          await WebSocket.connect('ws://127.0.0.1:${server.port}/tui'),
        );
        await peer.call('hello', {
          'protocol': 1,
          'token': 'window-test-token',
          'client_id': 'same-window',
          'features': ['window-lifecycle.v1'],
        });
        final scope = backend.registered.single;
        await peer.socket.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(backend.released, isEmpty);
        peer = _Peer(
          await WebSocket.connect('ws://127.0.0.1:${server.port}/tui'),
        );
        await peer.call('hello', {
          'protocol': 1,
          'token': 'window-test-token',
          'client_id': 'same-window',
          'features': ['window-lifecycle.v1'],
        });
        expect(backend.registered.last, scope);
        expect(backend.released, isEmpty);
        final closed = await peer.call('window.close', {});
        expect(closed['ok'], true);
        expect(backend.released, [scope]);
      } finally {
        await peer?.socket.close();
        await server.stop();
      }
    },
  );
  test('a window that disconnects without reconnecting is released', () async {
    final backend = _Backend();
    final server = TuiBridgeServer(backend: backend, discovery: _Discovery());
    await server.start();
    try {
      final peer = _Peer(
        await WebSocket.connect('ws://127.0.0.1:${server.port}/tui'),
      );
      await peer.call('hello', {
        'protocol': 1,
        'token': 'window-test-token',
        'client_id': 'closed-process',
        'features': ['window-lifecycle.v1'],
      });
      await peer.socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 5300));
      expect(backend.released, backend.registered);
    } finally {
      await server.stop();
    }
  });
}
