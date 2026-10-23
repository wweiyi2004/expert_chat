import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/desktop/workspace_tools.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart'
    show FakeSettings, FakeLlmProvider, InMemoryRepo, InMemoryLibraryFileStore;

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    searchMode: SearchMode.off,
    imageGenMode: ImageGenMode.off,
  );
}

ToolCall _call(String name, Map<String, dynamic> args) => ToolCall(
  index: 0,
  id: 'call-$name',
  name: name,
  argumentsJson: jsonEncode(args),
);

void main() {
  if (!const bool.fromEnvironment('DESKTOP_WORKSPACE_NATIVE_TEST')) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<
    ({
      ProviderContainer container,
      CliDesktopWorkspaceHost host,
      Directory root,
    })
  >
  setup(FakeLlmProvider model) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final root = await Directory.systemTemp.createTemp('chat-workspace-test-');
    final db = AppDatabase(NativeDatabase.memory());
    final host = CliDesktopWorkspaceHost(
      executable: p.absolute(
        'next',
        'target',
        'debug',
        Platform.isWindows ? 'expert-desktop.exe' : 'expert-desktop',
      ),
      dataDirectory: p.join(root.path, 'state'),
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(prefs),
        libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        settingsControllerProvider.overrideWith(_Settings.new),
        llmProvider.overrideWithValue(model),
        desktopWorkspaceHostProvider.overrideWithValue(host),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
      if (await root.parent.resolveSymbolicLinks() !=
              await Directory.systemTemp.resolveSymbolicLinks() ||
          !p.basename(root.path).startsWith('chat-workspace-test-')) {
        throw StateError('Unexpected fixture directory');
      }
      await root.delete(recursive: true);
    });
    await container.read(chatControllerProvider.future);
    return (container: container, host: host, root: root);
  }

  test(
    'work mode automatically exposes default workspace tools and returns real file content to the model',
    () async {
      final model = FakeLlmProvider(
        const [],
        scriptedChunks: [
          [
            ChatChunk(toolCalls: [_call('coding_workspace_info', {})]),
          ],
          [
            ChatChunk(
              toolCalls: [
                _call('coding_write_file', {
                  'scope': 'root',
                  'path': 'hello.txt',
                  'content': 'workspace result',
                  'expected_sha256': 'new',
                }),
              ],
            ),
          ],
          [
            ChatChunk(
              toolCalls: [
                _call('coding_read_file', {
                  'scope': 'root',
                  'path': 'hello.txt',
                }),
              ],
            ),
          ],
          [
            const ChatChunk(
              contentDelta: '文件已创建并读取核验。',
              usage: LlmUsage(
                inputTokens: 200,
                outputTokens: 20,
                cachedInputTokens: 100,
                cacheReported: true,
              ),
            ),
          ],
        ],
      );
      final fixture = await setup(model);
      final ctrl = fixture.container.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      ctrl.setWorkMode(true);
      await ctrl.sendMessage('在默认工作区创建文件并核对');
      expect(model.calls, hasLength(4));
      final current = fixture.container
          .read(chatControllerProvider)
          .requireValue
          .current!;
      final insight = fixture.container.read(
        workSessionInsightsProvider,
      )[current.id]!;
      expect(
        insight.messages.any((m) => m.content.contains('workspace result')),
        isTrue,
      );
      expect(insight.cachedTokens, 100);
      expect(
        insight.cacheComplete,
        isFalse,
        reason: 'Earlier tool requests had no usage',
      );
      expect(
        current.activePath.last.searchActivities.any(
          (a) => a.resultText?.contains('workspace result') ?? false,
        ),
        isTrue,
      );
      expect(
        model.toolCalls.first!.map((t) => t.name),
        containsAll(workspaceToolNames),
      );
      final workspace = await fixture.host.defaultWorkspace();
      expect(
        await File(p.join(workspace.root, 'hello.txt')).readAsString(),
        'workspace result',
      );
      expect(
        model.calls.last.any(
          (m) => m.toolCallId != null && m.content.contains('workspace result'),
        ),
        isTrue,
      );
      expect(
        fixture.container.read(conversationWorkspaceBindingsProvider),
        isEmpty,
      );
    },
  );

  test(
    'selected read-only workspace rejects model writes without using default',
    () async {
      final model = FakeLlmProvider(
        const [],
        scriptedChunks: [
          [
            ChatChunk(
              toolCalls: [
                _call('coding_write_file', {
                  'scope': 'root',
                  'path': 'blocked.txt',
                  'content': 'no',
                  'expected_sha256': 'new',
                }),
              ],
            ),
          ],
          [const ChatChunk(contentDelta: '目录只读，未写入。')],
        ],
      );
      final f = await setup(model);
      final project = await Directory(p.join(f.root.path, 'project')).create();
      await f.host.add(
        id: 'project',
        name: '只读工程',
        path: project.path,
        access: WorkspaceAccess.readOnly,
      );
      final ctrl = f.container.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      ctrl.setWorkMode(true);
      final id = f.container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      await f.container
          .read(conversationWorkspaceBindingsProvider.notifier)
          .select(id, 'project');
      await ctrl.sendMessage('写入测试文件');
      expect(await File(p.join(project.path, 'blocked.txt')).exists(), isFalse);
      expect(
        model.calls.last.any(
          (m) => m.toolCallId != null && m.content.contains('read-only'),
        ),
        isTrue,
      );
      expect(
        (await f.host.list()).any((w) => w.id == defaultDesktopWorkspaceId),
        isFalse,
      );
    },
  );

  test(
    'removed selected workspace blocks the turn instead of redirecting to default',
    () async {
      final model = FakeLlmProvider([
        const ChatChunk(contentDelta: 'should not run'),
      ]);
      final f = await setup(model);
      final ctrl = f.container.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      ctrl.setWorkMode(true);
      final id = f.container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      await f.container
          .read(conversationWorkspaceBindingsProvider.notifier)
          .select(id, 'removed');
      await ctrl.sendMessage('修改原项目');
      expect(model.calls, isEmpty);
      expect(await f.host.list(), isEmpty);
      expect(
        f.container.read(chatControllerProvider).requireValue.error,
        contains('所选工作区已被移除'),
      );
    },
  );

  test(
    'chat mode never exposes file tools or creates a default workspace',
    () async {
      final model = FakeLlmProvider(
        const [],
        scriptedChunks: [
          [
            ChatChunk(
              toolCalls: [
                _call('coding_write_file', {
                  'scope': 'root',
                  'path': 'not-allowed.txt',
                  'content': 'no',
                  'expected_sha256': 'new',
                }),
              ],
            ),
          ],
          [const ChatChunk(contentDelta: '普通聊天')],
        ],
      );
      final f = await setup(model);
      final ctrl = f.container.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      await ctrl.sendMessage('你好');
      expect(model.calls, isNotEmpty);
      expect(
        model.toolCalls.every(
          (tools) =>
              (tools ?? []).every((t) => !workspaceToolNames.contains(t.name)),
        ),
        isTrue,
      );
      expect(await f.host.list(), isEmpty);
    },
  );
}
