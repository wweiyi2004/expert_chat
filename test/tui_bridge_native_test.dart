import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/atomic_windows_preferences_io.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'package:expert_chat/features/tui_bridge/server.dart';
import 'package:expert_chat/features/tui_bridge/discovery.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/task_plans.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:expert_chat/state/work_task_steering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryLibraryFileStore;

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async {
    final settings = await super.build();
    return settings.copyWith(
      searchMode: SearchMode.off,
      imageGenMode: ImageGenMode.off,
      subagentRoles: [settings.effectiveSubagentRoles.first],
    );
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _JournalFaults extends SharedPreferencesStorePlatform {
  _JournalFaults(this.delegate);
  final AtomicWindowsPreferencesStore delegate;
  int transientRootFailures = 0, failures = 0;
  bool permanent = false, throwFailure = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.chatSessionJournal.v1' &&
        (permanent ||
            transientRootFailures > 0 &&
                value is String &&
                value.contains('根任务运行身份已保存'))) {
      failures++;
      if (transientRootFailures > 0) transientRootFailures--;
      if (throwFailure) {
        throw StateError('synthetic journal persistence failure');
      }
      return false;
    }
    return delegate.setValue(type, key, value);
  }

  @override
  Future<Map<String, Object>> getAll() => delegate.getAll();
  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters p) =>
      delegate.getAllWithParameters(p);
  @override
  Future<bool> remove(String key) => delegate.remove(key);
  @override
  Future<bool> clear() => delegate.clear();
}

class _Request {
  _Request(this.messages, this.tools, this.token);
  final List<LlmRequestMessage> messages;
  final List<ToolSpec> tools;
  final CancelToken? token;
  final stream = StreamController<ChatChunk>();
}

class _Llm implements LlmProvider {
  final requests = <_Request>[];
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
    final request = _Request(
      List.of(messages),
      List.of(tools ?? []),
      cancelToken,
    );
    requests.add(request);
    unawaited(
      cancelToken?.whenCancel.then((_) {
        if (!request.stream.isClosed) unawaited(request.stream.close());
      }),
    );
    return request.stream.stream;
  }

  Future<_Request> request(int index) async {
    await until(() => requests.length > index);
    return requests[index];
  }

  Future<void> tools(
    int index,
    List<(String, Map<String, dynamic>)> calls,
  ) async {
    final r = await request(index);
    r.stream.add(
      ChatChunk(
        toolCalls: [
          for (var i = 0; i < calls.length; i++)
            ToolCall(
              index: i,
              id: 'call-$index-$i',
              name: calls[i].$1,
              argumentsJson: jsonEncode(calls[i].$2),
            ),
        ],
        finishReason: 'tool_calls',
      ),
    );
    await r.stream.close();
  }

  Future<void> finish(int index) async {
    final r = await request(index);
    r.stream.add(
      const ChatChunk(contentDelta: '完成，已经核验实际文件。', finishReason: 'stop'),
    );
    await r.stream.close();
  }
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('controller did not reach expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  if (!const bool.fromEnvironment('DESKTOP_WORKSPACE_NATIVE_TEST')) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ProviderContainer container;
  late ControllerBridgeBackend bridge;
  late _Llm llm;
  late AppDatabase db;
  late SharedPreferencesStorePlatform oldPreferencesStore;
  late _JournalFaults preferencesStore;
  late File preferencesFile;
  late String id;
  late PathProviderPlatform oldPaths;
  late TuiBridgeServer server;
  late WebSocket socket;
  late StreamIterator<dynamic> messages;
  var requestId = 0;
  Future<Map<String, Object?>> rpc(
    String method,
    Map<String, Object?> params,
  ) async {
    final key = 'native:${++requestId}';
    socket.add(
      jsonEncode({'v': 1, 'id': key, 'method': method, 'params': params}),
    );
    while (await messages.moveNext().timeout(const Duration(seconds: 15))) {
      final message = jsonDecode(messages.current as String) as Map;
      if (message['id'] != key) continue;
      if (message['ok'] != true) {
        final error = message['error'] as Map;
        throw BridgeFailure(
          error['code'] as String,
          error['message'] as String,
        );
      }
      return Map<String, Object?>.from(message['result'] as Map);
    }
    throw StateError('Bridge closed unexpectedly');
  }

  setUp(() async {
    oldPreferencesStore = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('expert-tui-native-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(p.join(root.path, 'support'));
    preferencesFile = File(
      p.join(root.path, 'support', 'shared_preferences.json'),
    );
    preferencesStore = _JournalFaults(
      await AtomicWindowsPreferencesStore.open(preferencesFile),
    );
    SharedPreferencesStorePlatform.instance = preferencesStore;
    db = AppDatabase(NativeDatabase(File(p.join(root.path, 'fixture.sqlite'))));
    llm = _Llm();
    final host = CliDesktopWorkspaceHost(
      executable: p.absolute(
        const String.fromEnvironment(
          'DESKTOP_WORKSPACE_TEST_EXECUTABLE',
          defaultValue: 'next/target/debug/expert-desktop.exe',
        ),
      ),
      dataDirectory: p.join(root.path, 'state'),
    );
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        conversationRepositoryProvider.overrideWithValue(
          DriftConversationRepository(db),
        ),
        libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
        settingsControllerProvider.overrideWith(_Settings.new),
        llmProvider.overrideWithValue(llm),
        desktopWorkspaceHostProvider.overrideWithValue(host),
      ],
    );
    await container.read(chatControllerProvider.future);
    bridge = ControllerBridgeBackend(container);
    final discovery = BridgeDiscovery(Directory(p.join(root.path, 'tui')));
    server = TuiBridgeServer(backend: bridge, discovery: discovery);
    await server.start();
    final token =
        (jsonDecode(await discovery.file.readAsString()) as Map)['token'];
    socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/tui');
    messages = StreamIterator(socket);
    await rpc('hello', {
      'protocol': 1,
      'token': token,
      'client_id': 'native-fixture',
    });
    final project = await Directory(p.join(root.path, 'project')).create();
    final workspace = await rpc('workspace.register', {
      'path': project.path,
      'access': 'read-write',
      'confirmed': true,
    });
    id =
        (await rpc('session.new', {
              'title': '[TUI测试] isolated native fixture',
              'workspace_id': (workspace['workspace'] as Map)['id'],
            }))['session_id']
            as String;
    await rpc('session.open', {'session_id': id});
  });
  tearDown(() async {
    await socket.close();
    await messages.cancel();
    await server.stop();
    final controller = container.read(chatControllerProvider.notifier);
    final runtimeLogs = container.read(workRuntimeLogsProvider.notifier);
    final runtime = container.read(workAgentsProvider);
    container.dispose();
    await controller.flushSessionCheckpointWrites();
    for (final r in llm.requests) {
      if (!r.stream.isClosed) await r.stream.close();
    }
    await Future<void>.delayed(Duration.zero);
    await runtime.flushJournal();
    await runtimeLogs.flush();
    await preferencesStore.delegate.flush();
    await db.close();
    PathProviderPlatform.instance = oldPaths;
    SharedPreferencesStorePlatform.instance = oldPreferencesStore;
    SharedPreferences.resetStatic();
    final absolute = await root.resolveSymbolicLinks();
    final temporary = await Directory.systemTemp.resolveSymbolicLinks();
    if (!p.isWithin(temporary, absolute) ||
        !p.basename(absolute).startsWith('expert-tui-native-')) {
      throw StateError('Invalid fixture cleanup target');
    }
    await Directory(absolute).delete(recursive: true);
  });
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) => rpc(method, {'session_id': id, ...params});
  Future<PendingWorkApproval> approval() async {
    await until(
      () => container
          .read(workApprovalsProvider)
          .any((a) => a.conversationId == id),
    );
    return container
        .read(workApprovalsProvider)
        .firstWhere((a) => a.conversationId == id);
  }

  test(
    'nested file completion stays within the registered workspace',
    () async {
      final nested = await Directory(
        p.join(root.path, 'project', 'lib'),
      ).create();
      await File(
        p.join(nested.path, 'example.dart'),
      ).writeAsString('void main() {}');
      final listing = await call('files.list', {'query': 'lib/'});
      expect(
        (listing['files'] as List).any(
          (item) => (item as Map)['path'] == 'lib/example.dart',
        ),
        true,
      );
      await expectLater(
        call('files.list', {'query': '../'}),
        throwsA(isA<BridgeFailure>()),
      );
      final initialized = await Process.run('git', [
        'init',
        '--quiet',
        root.path,
      ]);
      expect(initialized.exitCode, 0);
      // The project is a subdirectory of a repo outside its grant. Startup must
      // not discover that parent's branch or inspect that parent's work tree.
      final snapshot = await call('snapshot.get');
      expect((snapshot['startup'] as Map)['branch'], isNull);
    },
  );

  test(
    'production discovery writes random token under protected user/SYSTEM ACL and rejects junctions',
    () async {
      final discovery = BridgeDiscovery(Directory(p.join(root.path, 'tui')));
      final record = jsonDecode(await discovery.file.readAsString()) as Map;
      expect(base64Url.decode(record['token'] as String).length, 32);
      final escaped = discovery.directory.path.replaceAll("'", "''");
      final check = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$ErrorActionPreference='Stop'; \$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; "
              "\$d=[IO.Directory]::GetAccessControl('$escaped'); if(-not \$d.AreAccessRulesProtected){throw 'Unprotected directory'}; "
              "foreach(\$a in @([IO.Directory]::GetAccessControl('$escaped').Access)+@([IO.File]::GetAccessControl('$escaped\\bridge.json').Access)){ "
              "\$s=\$a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value; if(\$s -ne \$sid -and \$s -ne 'S-1-5-18'){throw 'Unexpected principal'} }",
        ],
        environment: {...Platform.environment}
          ..removeWhere((key, _) => key.toLowerCase() == 'psmodulepath'),
        includeParentEnvironment: false,
      );
      expect(check.exitCode, 0, reason: '${check.stderr}');
      final target = await Directory(
        p.join(root.path, 'junction-target'),
      ).create();
      final link = p.join(root.path, 'junction');
      final created = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "\$ErrorActionPreference='Stop'; New-Item -ItemType Junction -Path '${link.replaceAll("'", "''")}' -Target '${target.path.replaceAll("'", "''")}' | Out-Null",
      ]);
      expect(created.exitCode, 0);
      try {
        await expectLater(
          BridgeDiscovery(Directory(link)).publish(12345),
          throwsStateError,
        );
        expect(await File(p.join(target.path, 'bridge.json')).exists(), false);
      } finally {
        await Directory(link).delete();
      }
    },
  );

  test(
    'controller executor blocks writes shell unknown MCP and child spawning in plan mode',
    () async {
      await call('mode.set', {'mode': 'plan'});
      await call('message.send', {'text': '只规划，禁止修改'});
      final first = await llm.request(0);
      expect(
        first.tools.map((t) => t.name),
        isNot(contains('coding_write_file')),
      );
      expect(
        first.tools.map((t) => t.name),
        isNot(contains('work_run_command')),
      );
      await llm.tools(0, [
        (
          'coding_write_file',
          {
            'path': 'blocked.txt',
            'content': 'blocked',
            'expected_sha256': 'new',
          },
        ),
        ('work_run_command', {'command': 'Set-Content blocked.txt blocked'}),
        ('unknown_mcp_mutation', {}),
        ('work_spawn_agent', {'task': 'write a file'}),
      ]);
      final next = await llm.request(1);
      final replies = next.messages
          .where((m) => m.role.name == 'tool')
          .map((m) => m.content)
          .join('\n');
      expect(replies, contains('计划模式'));
      expect(
        await File(p.join(root.path, 'project', 'blocked.txt')).exists(),
        false,
      );
      expect(container.read(workApprovalsProvider), isEmpty);
      expect(
        container.read(workAgentsProvider).records.where((a) => !a.external),
        isEmpty,
      );
      await llm.finish(1);
      await until(
        () =>
            container.read(taskPlansProvider)[id]?.status ==
            TaskPlanStatus.awaitingApproval,
      );
      await call('task.stop');
      await until(
        () => !container
            .read(chatControllerProvider.notifier)
            .isConversationRunning(id),
      );
    },
  );
  test(
    'live plan tightening while approval is waiting prevents the approved write',
    () async {
      await call('message.send', {'text': '新建 blocked.txt'});
      await llm.tools(0, [
        (
          'coding_write_file',
          {
            'path': 'blocked.txt',
            'content': 'blocked',
            'expected_sha256': 'new',
          },
        ),
      ]);
      final pending = await approval();
      await call('mode.set', {'mode': 'plan'});
      await call('approval.decide', {'id': pending.id, 'decision': 'once'});
      final next = await llm.request(1);
      expect(
        next.messages.where((m) => m.role.name == 'tool').last.content,
        contains('计划模式'),
      );
      expect(
        await File(p.join(root.path, 'project', 'blocked.txt')).exists(),
        false,
      );
      await llm.finish(1);
      await until(
        () =>
            container.read(taskPlansProvider)[id]?.status ==
            TaskPlanStatus.awaitingApproval,
      );
      await call('task.stop');
      await until(
        () => !container
            .read(chatControllerProvider.notifier)
            .isConversationRunning(id),
      );
    },
  );
  test(
    'existing child rechecks live plan policy for executor and recursive control tools',
    () async {
      await call('message.send', {'text': '检查子代理权限收紧'});
      await llm.request(0);
      final runtime = container.read(workAgentsProvider);
      final parent = runtime.records.singleWhere((a) => a.external);
      final childId = runtime.spawn(
        parentId: parent.id,
        task: '准备修改 child.txt',
        readOnly: false,
        ownedPaths: ['child.txt'],
      );
      await llm.request(1);
      final tree = (await call('agents.list'))['agents'] as List;
      expect((tree.first as Map)['id'], parent.id);
      expect((tree.first as Map)['name'], '主代理');
      expect((tree[1] as Map)['id'], childId);
      expect((tree[1] as Map)['parent_id'], parent.id);
      await call('mode.set', {'mode': 'plan'});
      await llm.tools(1, [
        (
          'coding_write_file',
          {'path': 'child.txt', 'content': 'blocked', 'expected_sha256': 'new'},
        ),
        ('work_run_command', {'command': 'Set-Content child.txt blocked'}),
        ('unknown_mcp_mutation', {}),
        ('work_spawn_agent', {'task': 'recursive mutation'}),
      ]);
      final next = await llm.request(2);
      expect(
        next.messages
            .where((m) => m.role.name == 'tool')
            .map((m) => m.content)
            .join('\n'),
        contains('计划模式'),
      );
      expect(
        await File(p.join(root.path, 'project', 'child.txt')).exists(),
        false,
      );
      expect(container.read(workApprovalsProvider), isEmpty);
      expect(runtime.records.where((a) => !a.external).length, 1);
      await call('task.stop');
      await until(
        () => !container
            .read(chatControllerProvider.notifier)
            .isConversationRunning(id),
      );
    },
  );
  test(
    'waiting for a child remains active and rejects target changes',
    () async {
      await call('message.send', {'text': '等待子代理结果'});
      await llm.request(0);
      final runtime = container.read(workAgentsProvider);
      final parent = runtime.records.singleWhere((a) => a.external);
      runtime.spawn(parentId: parent.id, task: '只读检查', readOnly: true);
      await llm.request(1);
      await llm.finish(0);
      final controller = container.read(chatControllerProvider.notifier);
      await until(() => !controller.isConversationRunning(id));
      final snapshot = await call('snapshot.get');
      final session = snapshot['session'] as Map;
      expect(session['status'], 'running');
      await expectLater(call('task.resume'), throwsA(isA<BridgeFailure>()));
      await expectLater(
        call('workspace.set', {'workspace_id': session['workspace_id']}),
        throwsA(isA<BridgeFailure>()),
      );
      await expectLater(
        call('message.send', {'text': '不能启动第二个任务'}),
        throwsA(isA<BridgeFailure>()),
      );
      final queued = await call('queue.add', {'text': '继续保持只读'});
      expect(queued['id'], isNotEmpty);
      await call('task.stop');
      await until(() => !controller.isConversationRunning(id));
    },
  );

  for (final throwFailure in [false, true]) {
    test(
      'real Drift and atomic prefs stop/resume retries transient root journal failure (throw=$throwFailure)',
      () async {
        Future<void> validPreferences() async {
          final bytes = await preferencesFile.readAsBytes();
          expect(bytes, isNotEmpty);
          expect(jsonDecode(utf8.decode(bytes)), isA<Map>());
        }

        await validPreferences();
        final proof = File(p.join(root.path, 'project', 'proof.txt'));
        await proof.writeAsString('BEFORE');
        await call('message.send', {
          'text': 'Read proof then propose writing it',
        });
        await llm.tools(0, [
          ('coding_read_file', {'scope': 'root', 'path': 'proof.txt'}),
        ]);
        final request = await llm.request(1);
        final receipt =
            jsonDecode(
                  request.messages
                      .lastWhere((m) => m.role.name == 'tool')
                      .content,
                )
                as Map;
        await llm.tools(1, [
          (
            'coding_write_file',
            {
              'scope': 'root',
              'path': 'proof.txt',
              'content': 'AFTER',
              'expected_sha256': receipt['sha256'],
            },
          ),
        ]);
        await approval();
        await validPreferences();
        await call('task.stop');
        final controller = container.read(chatControllerProvider.notifier);
        await until(() => !controller.isConversationRunning(id));
        await controller.flushSessionCheckpointWrites();
        await validPreferences();
        preferencesStore
          ..throwFailure = throwFailure
          ..transientRootFailures = 1;
        await call('task.resume');
        await llm.request(2);
        await llm.tools(2, [
          ('coding_read_file', {'scope': 'root', 'path': 'proof.txt'}),
        ]);
        await llm.request(3);
        await llm.finish(3);
        await until(() => !controller.isConversationRunning(id));
        await controller.flushSessionCheckpointWrites();
        await validPreferences();
        expect(preferencesStore.failures, 1);
        expect(controller.errorForSession(id), isNull);
        expect(await proof.readAsString(), 'BEFORE');
        final persisted = await DriftConversationRepository(
          db,
        ).loadConversation(id);
        expect(
          persisted.activePath.any(
            (m) => m.role.name == 'user' && m.content.contains('继续完成任务'),
          ),
          true,
        );
        final json = jsonDecode(await preferencesFile.readAsString()) as Map;
        expect(json['flutter.chatSessionJournal.v1'], isA<String>());
        expect(
          (jsonDecode(json['flutter.chatSessionJournal.v1'] as String) as List),
          isNotEmpty,
        );
      },
    );
  }
  test(
    'permanent real-prefs journal rejection remains fail closed before tools or model',
    () async {
      preferencesStore.permanent = true;
      await call('message.send', {
        'text': 'Do not execute without durable root identity',
      });
      final controller = container.read(chatControllerProvider.notifier);
      await until(
        () =>
            !controller.isConversationRunning(id) &&
            controller.errorForSession(id) != null,
      );
      await controller.flushSessionCheckpointWrites();
      expect(llm.requests, isEmpty);
      expect(preferencesStore.failures, greaterThanOrEqualTo(3));
      expect(container.read(workApprovalsProvider), isEmpty);
      expect(controller.errorForSession(id), contains('持久化失败'));
    },
  );
  test(
    'shared controller workflow: queue, write, command approval, diff, stop, resume and acceptance',
    () async {
      await call('message.send', {'text': '创建 hello.txt 并运行检查'});
      await llm.request(0);
      final queued = await call('queue.add', {'text': '保留 UTF-8 正文'});
      expect(
        container
            .read(workTaskSteeringProvider)
            .snapshot(id)
            .any((e) => e['id'] == queued['id']),
        true,
      );
      final removed = await call('queue.add', {'text': '撤回这条'});
      expect(
        (await call('queue.remove', {'id': removed['id']}))['text'],
        '撤回这条',
      );
      await expectLater(
        call('workspace.set', {'workspace_id': 'invalid'}),
        throwsA(isA<BridgeFailure>()),
      );
      await llm.tools(0, [
        (
          'coding_write_file',
          {
            'scope': 'root',
            'path': 'hello.txt',
            'content': 'hello\n',
            'expected_sha256': 'new',
          },
        ),
      ]);
      final write = await approval();
      final pendingPreview = await call('snapshot.get');
      expect(
        ((pendingPreview['approvals'] as List).first as Map)['diff'],
        contains('+hello'),
      );
      expect(
        (pendingPreview['steps'] as List).any(
          (s) => (s as Map)['status'] == 'approval',
        ),
        true,
      );
      await call('approval.decide', {'id': write.id, 'decision': 'once'});
      final second = await llm.request(1);
      expect(
        second.messages.map((m) => m.content).join('\n'),
        contains('保留 UTF-8 正文'),
      );
      expect(
        await File(p.join(root.path, 'project', 'hello.txt')).readAsString(),
        'hello\n',
      );
      await llm.tools(1, [
        (
          'work_run_command',
          {'command': 'Write-Output verified', 'timeout_seconds': 10},
        ),
      ]);
      final command = await approval();
      await call('approval.decide', {'id': command.id, 'decision': 'once'});
      await llm.request(2);
      await llm.tools(2, [
        ('coding_read_file', {'scope': 'root', 'path': 'hello.txt'}),
      ]);
      await llm.request(3);
      await llm.finish(3);
      final controller = container.read(chatControllerProvider.notifier);
      await until(() => !controller.isConversationRunning(id));
      final snapshot = await bridge.snapshot(id);
      expect(
        (snapshot['steps'] as List)
            .map((s) => (s as Map)['round_id'])
            .whereType<String>()
            .toSet()
            .length,
        greaterThanOrEqualTo(3),
      );
      final writeSteps = (snapshot['steps'] as List).where(
        (step) => (step as Map)['verb'] == '编辑',
      );
      expect(
        writeSteps.any(
          (step) => (step as Map)['added'] == 1 && step['removed'] == 0,
        ),
        true,
      );
      expect(
        writeSteps.every((step) => (step as Map)['object'] == 'hello.txt'),
        true,
      );
      expect(
        (snapshot['steps'] as List).any(
          (step) =>
              (step as Map)['verb'] == '运行' &&
              step['object'] == 'Write-Output verified',
        ),
        true,
      );
      expect(
        (snapshot['changes'] as List),
        isNotEmpty,
        reason:
            '${container.read(workChangesProvider).map((c) => [c.path, c.assistantId, c.conversationId]).toList()} path=${container.read(chatControllerProvider).requireValue.conversations.firstWhere((c) => c.id == id).activePath.map((m) => [m.id, m.role.name, m.content]).toList()}',
      );
      final changes = (await call('changes.list'))['changes'] as List;
      final diff = await call('changes.diff', {
        'id': (changes.first as Map)['id'],
      });
      expect((diff['diff'] as List).join('\n'), contains('+hello'));
      await call('task.accept');
      expect(
        ((await bridge.snapshot(id))['session'] as Map)['status'],
        'accepted',
      );
      await call('message.send', {'text': '继续做一次只读检查'});
      await llm.request(4);
      await call('task.stop');
      await until(() => !controller.isConversationRunning(id));
      await call('task.resume');
      await llm.request(5);
      await llm.finish(5);
      await until(() => !controller.isConversationRunning(id));
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .any((c) => c.id == id && c.title.startsWith('[TUI测试]')),
        true,
      );
      expect(
        ((await bridge.snapshot(id))['session'] as Map)['request_count'],
        greaterThanOrEqualTo(6),
      );
      final finalTree = (await call('agents.list'))['agents'] as List;
      expect(
        finalTree.where((row) => (row as Map)['parent_id'] == null).length,
        1,
      );
      expect(
        (finalTree.first as Map)['id'],
        controller.taskSnapshotFor(id)?['agentRootId'],
      );
    },
  );
}
