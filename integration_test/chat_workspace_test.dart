import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../test/widget_test.dart'
    show FakeSettings, FakeLlmProvider, InMemoryRepo, InMemoryLibraryFileStore;

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    searchMode: SearchMode.off,
    imageGenMode: ImageGenMode.off,
  );
}

ChatChunk write(String path) => ChatChunk(
  toolCalls: [
    ToolCall(
      index: 0,
      id: 'native-$path',
      name: 'coding_write_file',
      argumentsJson: jsonEncode({
        'scope': 'root',
        'path': path,
        'content': 'verified by real MCP',
        'expected_sha256': 'new',
      }),
    ),
  ],
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'work chat uses default workspace and can switch to a named project',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final root = await Directory.systemTemp.createTemp(
        'chat-workspace-native-',
      );
      final project = await Directory(p.join(root.path, 'project')).create();
      final host = CliDesktopWorkspaceHost(
        dataDirectory: p.join(root.path, 'state'),
      );
      await host.add(
        id: 'project',
        name: '项目工作区',
        path: project.path,
        access: WorkspaceAccess.readWrite,
      );
      final model = FakeLlmProvider(
        const [],
        scriptedChunks: [
          [write('default.txt')],
          [const ChatChunk(contentDelta: '默认工作区文件已创建。')],
          [write('project.txt')],
          [const ChatChunk(contentDelta: '项目工作区文件已创建。')],
        ],
      );
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
          settingsControllerProvider.overrideWith(_Settings.new),
          llmProvider.overrideWithValue(model),
          desktopWorkspaceHostProvider.overrideWithValue(host),
        ],
      );
      final imageKey = GlobalKey();
      try {
        await container.read(chatControllerProvider.future);
        final controller = container.read(chatControllerProvider.notifier);
        controller.newConversation();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: RepaintBoundary(
              key: imageKey,
              child: const MaterialApp(home: ChatPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('工作').first);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('chat-workspace-bar')),
          findsOneWidget,
        );
        await controller.sendMessage('在默认工作区创建测试文件');
        await tester.pumpAndSettle();
        final defaultWorkspace = await host.defaultWorkspace();
        expect(
          await File(
            p.join(defaultWorkspace.root, 'default.txt'),
          ).readAsString(),
          'verified by real MCP',
        );
        await tester.tap(find.byTooltip('工作选项').first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('select-workspace-project')),
        );
        await tester.pumpAndSettle();
        await controller.sendMessage('在所选项目创建测试文件');
        await tester.pumpAndSettle();
        expect(
          await File(p.join(project.path, 'project.txt')).readAsString(),
          'verified by real MCP',
        );
        expect(
          await File(p.join(defaultWorkspace.root, 'project.txt')).exists(),
          isFalse,
        );
        expect(
          find.byKey(const ValueKey('chat-workspace-bar')),
          findsOneWidget,
        );
        expect(model.calls, hasLength(4));
        expect(tester.takeException(), isNull);
        final output = Platform.environment['EXPERT_WORKSPACE_SCREENSHOT'];
        if (output != null) {
          final boundary =
              imageKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(output).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await db.close();
        if (await root.parent.resolveSymbolicLinks() !=
                await Directory.systemTemp.resolveSymbolicLinks() ||
            !p.basename(root.path).startsWith('chat-workspace-native-')) {
          throw StateError('Unexpected fixture directory');
        }
        await root.delete(recursive: true);
      }
    },
  );
}
