import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:crypto/crypto.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/desktop/file_edit.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/desktop/workspace_tools.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:expert_chat/platform/preferences.dart';
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

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

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
    'invalid scope reports valid choices and the next tool round recovers',
    () async {
      final model = FakeLlmProvider(
        const [],
        separateAuxiliary: true,
        scriptedChunks: [
          [
            ChatChunk(
              toolCalls: [
                _call('coding_list_directory', {'scope': 'AI', 'path': '.'}),
              ],
            ),
          ],
          [
            ChatChunk(
              toolCalls: [
                _call('coding_list_directory', {'scope': 'root', 'path': '.'}),
              ],
            ),
          ],
          [const ChatChunk(contentDelta: '目录已读取')],
        ],
      );
      final fixture = await setup(model);
      final ctrl = fixture.container.read(chatControllerProvider.notifier);
      ctrl.newConversation(workMode: true, forceNew: true);
      await ctrl.sendMessage('查看当前目录');
      expect(model.calls, hasLength(3));
      final error = model.calls[1]
          .where((m) => m.toolCallId != null)
          .map((m) => m.content)
          .firstWhere((s) => s.contains('invalid_scope'));
      final data = jsonDecode(error) as Map;
      expect(data['available_scopes'], ['root']);
      expect(data['execution_outcome'], 'failed');
      expect(data['retryable'], true);
      final tools = withFileEdit(model.toolCalls.first!);
      for (final tool in tools.where(
        (t) => [
          'coding_list_directory',
          'coding_read_file',
          'coding_edit_file',
          'work_deliver_files',
        ].contains(t.name),
      )) {
        expect((tool.parameters['properties'] as Map)['scope']['enum'], [
          'root',
        ]);
      }
      expect(
        model.calls.last.any(
          (m) => m.toolCallId != null && m.content.contains('entries'),
        ),
        isTrue,
      );
    },
  );

  test(
    'work mode automatically exposes default workspace tools and returns real file content to the model',
    () async {
      final model = FakeLlmProvider(
        const [],
        separateAuxiliary: true,
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
      // Approval prompts are covered by work_permissions_test.
      await fixture.container
          .read(sessionPolicyProvider.notifier)
          .save(
            fixture.container
                .read(chatControllerProvider)
                .requireValue
                .currentId!,
            const SessionPolicy(approval: WorkApprovalMode.full),
          );
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
        separateAuxiliary: true,
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
      await f.container
          .read(sessionPolicyProvider.notifier)
          .save(id, const SessionPolicy(approval: WorkApprovalMode.full));
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
    'coding_edit_file applies a partial edit as a versioned write with an undo record',
    () async {
      const original = 'alpha\nbeta\nbeta\ngamma\n';
      final originalSha = sha256.convert(utf8.encode(original)).toString();
      ToolCall edit(String id, String sha, List<Map<String, dynamic>> edits) =>
          ToolCall(
            index: 0,
            id: id,
            name: fileEditToolName,
            argumentsJson: jsonEncode({
              'scope': 'root',
              'path': 'notes.txt',
              'expected_sha256': sha,
              'edits': edits,
            }),
          );
      final model = FakeLlmProvider(
        const [],
        separateAuxiliary: true,
        scriptedChunks: [
          [
            ChatChunk(
              toolCalls: [
                _call('coding_write_file', {
                  'scope': 'root',
                  'path': 'notes.txt',
                  'content': original,
                  'expected_sha256': 'new',
                }),
              ],
            ),
          ],
          [
            ChatChunk(
              toolCalls: [
                edit('edit-ambiguous', originalSha, [
                  {'old_string': 'beta', 'new_string': 'BETA'},
                ]),
              ],
            ),
          ],
          [
            ChatChunk(
              toolCalls: [
                edit('edit-ok', originalSha, [
                  {'old_string': 'alpha', 'new_string': 'ALPHA'},
                  {
                    'old_string': 'beta',
                    'new_string': 'B',
                    'replace_all': true,
                  },
                ]),
              ],
            ),
          ],
          [
            ChatChunk(
              toolCalls: [
                edit('edit-stale', originalSha, [
                  {'old_string': 'gamma', 'new_string': 'G'},
                ]),
              ],
            ),
          ],
          [const ChatChunk(contentDelta: '已局部修改。')],
        ],
      );
      final fixture = await setup(model);
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(
        p.join(fixture.root.path, 'support'),
      );
      addTearDown(() => PathProviderPlatform.instance = oldPaths);
      final ctrl = fixture.container.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      ctrl.setWorkMode(true);
      await fixture.container
          .read(sessionPolicyProvider.notifier)
          .save(
            fixture.container
                .read(chatControllerProvider)
                .requireValue
                .currentId!,
            const SessionPolicy(approval: WorkApprovalMode.full),
          );
      await ctrl.sendMessage('局部修改 notes.txt');
      expect(
        model.toolCalls.any(
          (tools) => (tools ?? []).any((t) => t.name == fileEditToolName),
        ),
        isTrue,
      );
      String reply(String id) => model.calls
          .expand((call) => call)
          .lastWhere(
            (m) => m.toolCallId == id,
            orElse: () => throw StateError(
              'no reply for $id; tool replies: ${model.calls.expand((c) => c).where((m) => m.toolCallId != null).map((m) => '${m.toolCallId}=${m.content}').toList()}',
            ),
          )
          .content;
      expect(reply('call-coding_write_file'), contains('sha256'));
      expect(reply('edit-ambiguous'), contains('出现 2 次'));
      expect(reply('edit-ok'), contains('sha256'));
      expect(reply('edit-ok'), isNot(contains('撤销记录未保存')));
      expect(reply('edit-stale'), contains('File changed since it was read'));
      final workspace = await fixture.host.defaultWorkspace();
      expect(
        await File(p.join(workspace.root, 'notes.txt')).readAsString(),
        'ALPHA\nB\nB\ngamma\n',
      );
      await fixture.container.read(workChangesProvider.notifier).ready;
      final changes = fixture.container.read(workChangesProvider);
      final change = changes.lastWhere(
        (c) => c.path == 'notes.txt',
        orElse: () => throw StateError(
          'changes: ${changes.map((c) => '${c.path}:${c.beforeHash}').toList()}',
        ),
      );
      expect(change.before, original);
      expect(change.after, 'ALPHA\nB\nB\ngamma\n');
      expect(change.beforeHash, originalSha);
    },
  );
  test(
    'read-only workspace calls in one batch keep results on their own activities',
    () async {
      // Distinct indices: streamed deltas sharing an index merge into one call.
      ToolCall read(int index, String id, String path) => ToolCall(
        index: index,
        id: id,
        name: 'coding_read_file',
        argumentsJson: jsonEncode({'scope': 'root', 'path': path}),
      );
      ToolCall write(int index, String id, String path, String content) =>
          ToolCall(
            index: index,
            id: id,
            name: 'coding_write_file',
            argumentsJson: jsonEncode({
              'scope': 'root',
              'path': path,
              'content': content,
              'expected_sha256': 'new',
            }),
          );
      final model = FakeLlmProvider(
        const [],
        separateAuxiliary: true,
        scriptedChunks: [
          [
            ChatChunk(
              toolCalls: [
                write(0, 'w1', 'one.txt', 'content one'),
                write(1, 'w2', 'two.txt', 'content two'),
              ],
            ),
          ],
          [
            ChatChunk(
              toolCalls: [read(0, 'r1', 'one.txt'), read(1, 'r2', 'two.txt')],
            ),
          ],
          [const ChatChunk(contentDelta: '已读取。')],
        ],
      );
      final fixture = await setup(model);
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(
        p.join(fixture.root.path, 'support'),
      );
      addTearDown(() => PathProviderPlatform.instance = oldPaths);
      final ctrl = fixture.container.read(chatControllerProvider.notifier);
      ctrl.newConversation();
      ctrl.setWorkMode(true);
      await fixture.container
          .read(sessionPolicyProvider.notifier)
          .save(
            fixture.container
                .read(chatControllerProvider)
                .requireValue
                .currentId!,
            const SessionPolicy(approval: WorkApprovalMode.full),
          );
      await ctrl.sendMessage('读取两个文件');
      final replies = {
        for (final m in model.calls.last)
          if (m.toolCallId != null) m.toolCallId!: m.content,
      };
      expect(replies['r1'], contains('content one'));
      expect(replies['r2'], contains('content two'));
      final activities = fixture.container
          .read(chatControllerProvider)
          .requireValue
          .current!
          .activePath
          .last
          .searchActivities;
      final byCall = {for (final a in activities) a.toolCallId: a};
      expect(byCall['r1']!.resultText, contains('content one'));
      expect(byCall['r1']!.resultText, isNot(contains('content two')));
      expect(byCall['r2']!.resultText, contains('content two'));
    },
  );
  test(
    'chat mode never exposes file tools or creates a default workspace',
    () async {
      final model = FakeLlmProvider(
        const [],
        separateAuxiliary: true,
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
