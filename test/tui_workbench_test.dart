import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo, FakeLlmProvider;

class _Llm extends FakeLlmProvider {
  _Llm()
    : super([
        const ChatChunk(contentDelta: 'Side answer', finishReason: 'stop'),
      ]);
  int requestCount = 0;
  List<LlmRequestMessage> lastMessages = [];
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
    requestCount++;
    lastMessages = List.of(messages);
    return super.streamChat(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, project;
  late ProviderContainer container;
  late ControllerBridgeBackend backend;
  late AppDatabase db;
  late String id;
  late _Llm llm;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('expert-workbench-');
    project = await Directory('${root.path}/project').create();
    db = AppDatabase(NativeDatabase.memory());
    llm = _Llm();
    final host = CliDesktopWorkspaceHost(
      executable: File('next/target/release/expert-desktop.exe').absolute.path,
      dataDirectory: '${root.path}/state',
    );
    await host.add(
      id: 'test',
      name: 'Test',
      path: project.path,
      access: WorkspaceAccess.readWrite,
    );
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        settingsControllerProvider.overrideWith(FakeSettings.new),
        desktopWorkspaceHostProvider.overrideWithValue(host),
        llmProvider.overrideWithValue(llm),
      ],
    );
    await container.read(chatControllerProvider.future);
    backend = ControllerBridgeBackend(container);
    id =
        (await backend.invoke('session.new', {
              'workspace_id': 'test',
              'title': 'Workbench fixture',
            }))['session_id']
            as String;
  });
  tearDown(() async {
    backend.closeWorkbench();
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    await db.close();
    await root.delete(recursive: true);
  });
  Future<Map<String, Object?>> call(
    String op, [
    Map<String, dynamic> a = const {},
  ]) => backend.invoke('terminal.action', {
    'action': op,
    'session_id': id,
    '_bridge_client_scope': 'fixture',
    ...a,
  });
  Future<Map<String, Object?>> done(String job) async {
    for (var i = 0; i < 150; i++) {
      final result = await call('wb.job', {'job_id': job});
      if (result['done'] == true || result['job_id'] == null) return result;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('Job timeout');
  }

  test(
    'directory permissions update existing root and keep child rules',
    () async {
      final host = container.read(desktopWorkspaceHostProvider);
      final private = await Directory('${project.path}/private').create();
      await host.setScope(
        workspace: 'test',
        name: 'private',
        path: private.path,
        access: WorkspaceAccess.deny,
      );
      Future<Map<String, Object?>> permissions() =>
          backend.invoke('terminal.query', {
            'topic': 'workspace.permissions',
            'session_id': id,
            'workspace_id': 'test',
          });
      final original = (await permissions())['workspace'] as Map;
      final rootScope =
          (original['scopes'] as List).firstWhere((s) => s['name'] == 'root')
              as Map;
      final args = <String, dynamic>{
        'workspace_id': 'test',
        'name': 'root',
        'expected_path': rootScope['path'],
        'expected_access': 'read-write',
        'access': 'read-only',
        'confirmed': true,
      };
      final result = await call('workspace.permission.set', args);
      expect((result['workspace'] as Map)['access'], 'read-only');
      expect(
        (await host.list())
            .singleWhere((w) => w.id == 'test')
            .scopes
            .singleWhere((s) => s.name == 'private')
            .access,
        WorkspaceAccess.deny,
      );
      expect(container.read(conversationWorkspaceBindingsProvider)[id], 'test');
      await expectLater(
        call('workspace.permission.set', args),
        throwsA(isA<BridgeFailure>().having((e) => e.code, 'code', 'conflict')),
      );
      await expectLater(
        backend.invoke('terminal.query', {
          'topic': 'workspace.permission.set',
          'session_id': id,
          ...args,
        }),
        throwsA(isA<BridgeFailure>()),
      );
      for (final access in ['deny', 'read-write']) {
        final current = (await permissions())['workspace'] as Map;
        await call('workspace.permission.set', {
          ...args,
          'expected_access': current['access'],
          'access': access,
        });
        expect(((await permissions())['workspace'] as Map)['access'], access);
      }
    },
  );

  test(
    'file picker starts in workspace and creates in the selected directory',
    () async {
      final directory = await Directory('${project.path}/中文 目录').create();
      final panel = await call('wb.files');
      expect((panel['data'] as Map)['path'], p.normalize(project.path));
      expect(
        (panel['fields'] as List).first['value'],
        p.normalize(project.path),
      );
      final folder = await call('wb.files', {'path': directory.path});
      expect((folder['data'] as Map)['path'], p.normalize(directory.path));
      await expectLater(
        call('wb.file.new', {'path': directory.path}),
        throwsA(isA<BridgeFailure>()),
      );
      final fresh = await call('wb.file.new', {
        'path': directory.path,
        'filename': '示例.py',
      });
      expect(fresh['path'], p.normalize(p.join(directory.path, '示例.py')));
      final saved = await call('wb.file.save', {
        'path': fresh['path'],
        'sha256': fresh['sha256'],
        'content': 'print(42)',
      });
      expect(await File(saved['path'] as String).readAsString(), 'print(42)');
      final reopened = await call('wb.file.open', {'path': saved['path']});
      expect(reopened['content'], 'print(42)');
      expect(llm.requestCount, 0);
    },
  );

  test('real file create save run and Git round trip', () async {
    final fresh = await call('wb.file.new', {'path': 'hello.py'});
    expect(fresh['sha256'], 'new');
    final saved = await call('wb.file.save', {
      'path': 'hello.py',
      'sha256': 'new',
      'content': 'print("WORKBENCH_OK")\n',
    });
    expect(
      await File('${project.path}/hello.py').readAsString(),
      contains('WORKBENCH_OK'),
    );
    final run = await call('wb.file.run', {
      'path': 'hello.py',
      'sha256': saved['sha256'],
    });
    expect(
      (await done(run['job_id'] as String))['data'].toString(),
      contains('WORKBENCH_OK'),
    );
    await Process.run('git', ['init'], workingDirectory: project.path);
    await Process.run('git', [
      'config',
      'user.name',
      'Fixture',
    ], workingDirectory: project.path);
    await Process.run('git', [
      'config',
      'user.email',
      'fixture@example.invalid',
    ], workingDirectory: project.path);
    await call('wb.git.stage', {'path': 'hello.py'});
    await call('wb.git.commit', {'message': 'Fixture'});
    expect(
      (await Process.run('git', [
        'log',
        '--oneline',
      ], workingDirectory: project.path)).stdout,
      contains('Fixture'),
    );
    expect(llm.requestCount, 0);
  });
  test('side conversation stays out of the main transcript', () async {
    await container
        .read(settingsControllerProvider.notifier)
        .setChatSkills(
          ChatSkillCatalog.factory(generalPrompt: 'CORE: speak naturally'),
        );
    final start = await call('wb.side.open', {'text': 'Explain the task'});
    Map<String, Object?> value = start;
    for (var i = 0; i < 100 && value['status'] == 'running'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      value = await call('wb.side.poll', {'job_id': start['job_id']});
    }
    expect(value['messages'].toString(), contains('Side answer'));
    expect(
      container.read(chatControllerProvider).requireValue.current!.messages,
      isEmpty,
    );
    expect(llm.requestCount, 1);
    expect(
      llm.lastMessages.any(
        (m) =>
            m.role == MessageRole.system &&
            m.content.contains('CORE: speak naturally'),
      ),
      isTrue,
    );
  });
  test(
    'schedules can be saved disabled and removed without executing a model',
    () async {
      final saved = await call('wb.automation.save', {
        'command': 'echo fixture',
        'seconds': '300',
      });
      final key = ((saved['data'] as Map)['schedules'] as List).single['id'];
      await call('wb.automation.toggle', {'schedule_id': key});
      expect(backend.hasTerminalSchedules, false);
      final removed = await call('wb.automation.remove', {'schedule_id': key});
      expect((removed['data'] as Map)['schedules'], isEmpty);
      expect(llm.requestCount, 0);
    },
  );

  test('query endpoint rejects writes before changing files or jobs', () async {
    for (final op in [
      'wb.file.save',
      'wb.file.run',
      'wb.automation.save',
      'wb.side.send',
    ]) {
      await expectLater(
        backend.invoke('terminal.query', {
          'topic': op,
          'session_id': id,
          '_bridge_client_scope': 'fixture',
          'path': 'query.txt',
          'sha256': 'new',
          'content': 'wrong endpoint',
          'command': 'echo wrong endpoint',
          'seconds': '300',
          'text': 'not a query',
        }),
        throwsA(
          isA<BridgeFailure>().having((e) => e.code, 'code', 'invalid_method'),
        ),
      );
    }
    expect(await File('${project.path}/query.txt').exists(), isFalse);
    await call('wb.file.save', {
      'path': 'query.txt',
      'sha256': 'new',
      'content': 'correct endpoint',
    });
    expect(
      await File('${project.path}/query.txt').readAsString(),
      'correct endpoint',
    );
    expect(llm.requestCount, 0);
  });

  test(
    'closing a window disables its schedules and rejects delayed actions',
    () async {
      backend.registerWindowClient('fixture');
      await call('wb.automation.save', {
        'command': 'echo fixture',
        'seconds': '3600',
      });
      expect(backend.hasTerminalSchedules, true);
      await backend.releaseClient('fixture');
      expect(backend.hasTerminalSchedules, false);
      final stored = container
          .read(sharedPrefsProvider)
          .getString('tuiSchedules.v1')!;
      expect(stored, contains('"enabled":false'));
      expect(
        () => call('wb.automation.save', {
          'command': 'echo late',
          'seconds': '3600',
        }),
        throwsA(
          isA<BridgeFailure>().having((e) => e.code, 'code', 'disconnected'),
        ),
      );
    },
  );

  test('schedule keeps its saved workspace when the session changes', () async {
    final second = await Directory('${root.path}/second').create();
    final host = container.read(desktopWorkspaceHostProvider);
    await host.add(
      id: 'second',
      name: 'Second',
      path: second.path,
      access: WorkspaceAccess.readWrite,
    );
    final saved = await call('wb.automation.save', {
      'command': "Set-Content -LiteralPath schedule-marker.txt -Value OK",
      'seconds': '3600',
    });
    final row = ((saved['data'] as Map)['schedules'] as List).single as Map;
    expect(row['workspace_id'], 'test');
    expect(row['cwd'], isNotEmpty);
    await container
        .read(conversationWorkspaceBindingsProvider.notifier)
        .select(id, 'second');
    final blocked = await call('wb.automation.run', {'schedule_id': row['id']});
    final blockedRow =
        ((blocked['data'] as Map)['schedules'] as List).single as Map;
    expect(blockedRow['last_error'], contains('工作区已变化'));
    expect(await File('${project.path}/schedule-marker.txt').exists(), isFalse);
    expect(await File('${second.path}/schedule-marker.txt').exists(), isFalse);
    await container
        .read(conversationWorkspaceBindingsProvider.notifier)
        .select(id, 'test');
    final started = await call('wb.automation.run', {'schedule_id': row['id']});
    final job =
        (((started['data'] as Map)['schedules'] as List).single
            as Map)['job_id'];
    for (var i = 0; i < 100; i++) {
      final status = await backend.invoke('terminal.query', {
        'topic': 'shell.status',
        'session_id': id,
        '_bridge_client_scope': 'fixture',
        'job_id': job,
      });
      if (status['done'] == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      await File('${project.path}/schedule-marker.txt').readAsString(),
      contains('OK'),
    );
    expect(await File('${second.path}/schedule-marker.txt').exists(), isFalse);
    expect(llm.requestCount, 0);
  });

  test(
    'legacy schedules require an explicit resave before they can run',
    () async {
      backend.closeWorkbench();
      final prefs = container.read(sharedPrefsProvider);
      await prefs.setString(
        'tuiSchedules.v1',
        '[{"id":"old","session":"$id","command":"echo old","seconds":300,"enabled":true}]',
      );
      backend = ControllerBridgeBackend(container);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final view = await call('wb.automation');
      final row = ((view['data'] as Map)['schedules'] as List).single as Map;
      expect(row['enabled'], false);
      expect(row['last_error'], contains('重新保存'));
      expect(backend.hasTerminalSchedules, false);
      await expectLater(
        call('wb.automation.toggle', {'schedule_id': 'old'}),
        throwsA(
          isA<BridgeFailure>().having(
            (e) => e.code,
            'code',
            'workspace_required',
          ),
        ),
      );
    },
  );
}
