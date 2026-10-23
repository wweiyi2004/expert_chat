import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/features/shell/app_shell.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'widget_test.dart'
    show FakeSettings, InMemoryRepo, InMemoryLibraryFileStore;
import 'desktop_workspaces_page_test.dart' show MemoryHost;

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    studyModeEnabled: false,
    creationModeEnabled: false,
  );
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('RENDER_DESKTOP_LAYOUT')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('desktop-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory =
        Platform.environment['EXPERT_LAYOUT_SCREENSHOT_DIR'] ??
        'output/desktop-layout';
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Expert Chat',
      packageName: 'test.desktop.layout',
      version: '3.6.1',
      buildNumber: '4109',
      buildSignature: '',
    );
    if (!const bool.fromEnvironment('RENDER_DESKTOP_LAYOUT')) return;
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await font.load();
    await icons.load();
  });

  testWidgets(
    'desktop project tree, centered composer, collapse and mode switching preserve the draft',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'desktopConversationWorkspaces': '{"project-chat":"project-one"}',
      });
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final repo = InMemoryRepo()
        ..store = [
          Conversation(id: 'welcome', title: '新对话'),
          Conversation(
            id: 'project-chat',
            workMode: true,
            title: '梳理项目结构',
            messages: [
              ChatMessage(
                id: 'project-user',
                role: MessageRole.user,
                content: '梳理目录与模块',
              ),
              ChatMessage(
                parentId: 'project-user',
                role: MessageRole.assistant,
                content: '已查看项目入口，下面是模块结构。',
                searchActivities: [
                  SearchActivity(
                    kind: SearchActivityKind.mcp,
                    query: '工作区',
                    status: SearchActivityStatus.done,
                    toolName: 'coding_list_directory',
                    toolArguments: '{"path":"src"}',
                    resultText: 'src/\n  main.dart\n  features/\n  services/',
                    startedAt: DateTime(2026),
                    finishedAt: DateTime(
                      2026,
                    ).add(const Duration(milliseconds: 120)),
                  ),
                ],
              ),
            ],
          ),
          Conversation(
            id: 'notes',
            title: '整理下一步计划',
            messages: [ChatMessage(role: MessageRole.user, content: '写下今天的计划')],
          ),
        ];
      final host = MemoryHost();
      await host.add(
        id: 'project-one',
        name: '我的项目',
        path: 'E:/Projects/example',
        access: WorkspaceAccess.readOnly,
      );
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(repo),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
          settingsControllerProvider.overrideWith(_Settings.new),
          desktopWorkspaceHostProvider.overrideWithValue(host),
        ],
      );
      final themeMode = ValueNotifier(ThemeMode.light);
      addTearDown(themeMode.dispose);
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(chatControllerProvider.future);
      await container
          .read(projectRepositoryProvider)
          .save(name: '设计资料', instructions: '', fileIds: []);
      await container
          .read(chatControllerProvider.notifier)
          .selectConversation('welcome');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ValueListenableBuilder<ThemeMode>(
            valueListenable: themeMode,
            builder: (context, mode, _) => MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: mode,
              home: const RepaintBoundary(
                key: ValueKey('desktop-render'),
                child: AppShell(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> filter(bool work) async {
        await tester.tap(
          find.byKey(
            ValueKey(work ? 'sidebar-filter-work' : 'sidebar-filter-chat'),
          ),
        );
        await tester.pumpAndSettle();
      }

      expect(find.text('梳理项目结构'), findsNothing);
      await filter(true);
      expect(find.byKey(const ValueKey('desktop-nav-chat')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('desktop-project-workspace-project-one')),
        findsOneWidget,
      );
      expect(find.text('梳理项目结构'), findsOneWidget);
      expect(find.text('设计资料'), findsNothing);
      await filter(false);
      expect(find.text('设计资料'), findsOneWidget);
      expect(find.text('今天想完成什么？'), findsOneWidget);
      final input = tester.getRect(
        find.byKey(const ValueKey('composer-input-box')),
      );
      expect(input.bottom, lessThan(740));
      expect(input.width, lessThanOrEqualTo(880));
      await capture(tester, 'welcome');
      await tester.enterText(
        find.byKey(const ValueKey('composer-text-field')),
        '保留这个草稿',
      );
      await tester.tap(find.byTooltip('收起侧边栏'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('composer-text-field')),
            )
            .controller!
            .text,
        '保留这个草稿',
      );
      expect(
        find.byKey(const ValueKey('desktop-project-conversations')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('展开侧边栏'));
      await tester.pumpAndSettle();
      expect(find.text('梳理项目结构'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('chat-work-mode-switch')),
          matching: find.text('工作'),
        ),
      );
      await tester.pumpAndSettle();
      final workConversationId = container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      expect(workConversationId, isNot('welcome'));
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .firstWhere((c) => c.id == 'welcome')
            .workMode,
        isFalse,
      );
      expect(find.text('E:/App/desktop-workspaces/default'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('composer-text-field')),
            )
            .controller!
            .text,
        '',
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('chat-workspace-bar'))).dy,
        greaterThan(
          tester
              .getBottomLeft(find.byKey(const ValueKey('composer-input-box')))
              .dy,
        ),
      );
      container.read(workSessionInsightsProvider.notifier).request(
        workConversationId,
        'fixture',
        'fixture-model',
        [
          const LlmRequestMessage(role: MessageRole.system, content: '上下文快照示例'),
          const LlmRequestMessage(role: MessageRole.user, content: '检查项目'),
        ],
        [],
      );
      container
          .read(workSessionInsightsProvider.notifier)
          .usage(
            workConversationId,
            'fixture',
            const LlmUsage(
              inputTokens: 1000,
              outputTokens: 100,
              cachedInputTokens: 800,
              cacheReported: true,
              cost: .01,
              currency: 'USD',
            ),
          );
      await tester.pumpAndSettle();
      expect(find.text('缓存 80.0%'), findsOneWidget);
      expect(find.text('USD 0.0100'), findsOneWidget);
      await capture(tester, 'work');
      await tester.tap(find.byKey(const ValueKey('work-context-details')));
      await tester.pumpAndSettle();
      expect(find.text('最近一次请求的上下文'), findsOneWidget);
      await tester.tap(find.text('1. system'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets);
      await tester.tap(find.byTooltip('关闭上下文'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
      await tester.pumpAndSettle();
      await capture(tester, 'attachment-tray');
      await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(900, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'compact');
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      await filter(true);
      await tester.tap(find.text('梳理项目结构'));
      await tester.pumpAndSettle();
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'project-chat',
      );
      expect(find.byKey(const ValueKey('desktop-chat-welcome')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('composer-input-box'))).bottom,
        greaterThan(800),
      );
      await capture(tester, 'conversation');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('chat-work-mode-switch')),
          matching: find.text('聊天'),
        ),
      );
      await tester.pumpAndSettle();
      final chatState = container.read(chatControllerProvider).requireValue;
      expect(chatState.currentId, isNot('project-chat'));
      expect(chatState.current!.workMode, isFalse);
      expect(chatState.current!.messages, isEmpty);
      final originalWork = chatState.conversations.firstWhere(
        (c) => c.id == 'project-chat',
      );
      expect(originalWork.workMode, isTrue);
      expect(originalWork.messages, hasLength(2));
      expect(
        container.read(conversationWorkspaceBindingsProvider)['project-chat'],
        'project-one',
      );
      expect(
        container.read(
          conversationWorkspaceBindingsProvider,
        )[chatState.currentId],
        isNull,
      );
      await filter(true);
      await tester.tap(find.text('梳理项目结构'));
      await tester.pumpAndSettle();
      themeMode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      await capture(tester, 'dark');
      expect(tester.takeException(), isNull);
      themeMode.value = ThemeMode.light;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-nav-tools')));
      await tester.pumpAndSettle();
      expect(container.read(shellTabProvider), ShellTab.tools);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-chat')));
      await tester.pumpAndSettle();
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'project-chat',
      );
      expect(
        container.read(conversationWorkspaceBindingsProvider)['project-chat'],
        'project-one',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('在项目中新建会话').first);
      await tester.pumpAndSettle();
      final projectConversationId = container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      expect(
        container.read(
          conversationWorkspaceBindingsProvider,
        )[projectConversationId],
        'project-one',
      );
      expect(
        container.read(chatControllerProvider).requireValue.current!.workMode,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('sidebar-new-chat')));
      await tester.pumpAndSettle();
      final defaultConversationId = container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      expect(
        container.read(
          conversationWorkspaceBindingsProvider,
        )[defaultConversationId],
        isNull,
      );
      expect(
        container.read(chatControllerProvider).requireValue.current!.workMode,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('desktop-nav-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('电脑工作区'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加工作区'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('workspace-name')),
        '新增项目',
      );
      await tester.enterText(
        find.byKey(const ValueKey('workspace-directory')),
        'E:/Projects/new-project',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-nav-chat')));
      await tester.pumpAndSettle();
      expect(find.text('新增项目'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
