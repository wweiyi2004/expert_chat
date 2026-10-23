import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/features/chat/widgets/conversation_history_list.dart';
import 'package:expert_chat/features/chat/widgets/composer_popover.dart';
import 'package:expert_chat/features/chat/widgets/session_policy_controls.dart';
import 'package:expert_chat/features/chat/widgets/work_round_activity.dart';
import 'package:expert_chat/features/shared/recovery_notice.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'desktop_workspaces_page_test.dart' show MemoryHost;
import 'widget_test.dart' show FakeSettings;

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'chat',
    conversations: [Conversation(id: 'chat')],
  );
}

class _ActivityChat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'a',
    conversations: [
      Conversation(id: 'a', title: '工作 A', workMode: true),
      Conversation(id: 'b', title: '工作 B', workMode: true),
    ],
  );
  void activity(String id, {bool complete = false}) {
    final previous = state.requireValue;
    state = AsyncData(
      previous.copyWith(
        runningConversationIds: {...previous.runningConversationIds, id}
          ..removeWhere((v) => complete && v == id),
        sessionCheckpoints: {
          ...previous.sessionCheckpoints,
          id: SessionExecutionCheckpoint(
            conversationId: id,
            status: complete
                ? SessionExecutionStatus.completed
                : SessionExecutionStatus.running,
            updatedAt: DateTime.now(),
          ),
        },
      ),
    );
  }
}

class _WorkChat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [Conversation(id: 'work', workMode: true)],
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('RENDER_HARNESS_UI')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('ui-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/harness-ui-$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async =>
      (await super.build()).copyWith(selectedModel: 'deepseek-v4.1-flash');
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('RENDER_HARNESS_UI')) return;
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'ordinary chat has no work directory or permission controls at narrow widths',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
          chatControllerProvider.overrideWith(_Chat.new),
          settingsControllerProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ChatPage(desktopShell: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-workspace-bar')), findsNothing);
      expect(find.byType(ComposerPermissionControl), findsNothing);
      expect(find.text('项目 / 执行位置'), findsNothing);
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('deepseek-v4.1-flash'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'popover title has breathing room and footer stays visible while list scrolls',
    (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showComposerPopover<void>(
                    context,
                    builder: (_) => ComposerPopoverFrame(
                      title: '项目与执行位置',
                      body: ListView(
                        shrinkWrap: true,
                        children: [
                          for (var i = 0; i < 30; i++)
                            ListTile(title: Text('项目 $i')),
                        ],
                      ),
                      footer: FilledButton(
                        onPressed: () {},
                        child: const Text('完成'),
                      ),
                    ),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final surface = tester.getRect(
        find.byKey(const ValueKey('composer-popover-surface')),
      );
      final title = tester.getRect(find.text('项目与执行位置'));
      expect(surface.top, greaterThanOrEqualTo(40));
      expect(title.top - surface.top, greaterThanOrEqualTo(14));
      expect(find.text('完成').hitTestable(), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('项目与执行位置').hitTestable(), findsOneWidget);
      expect(find.text('完成').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long execution history keeps collapse and stop reachable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkRoundActivity(
            reasoning: List.filled(100, '执行记录中的推理说明').join('\n'),
            activities: const [],
            running: true,
            onStop: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('work-round-collapse-bottom')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('停止任务').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('work-round-scroll'))).height,
      lessThanOrEqualTo(360),
    );
    await tester.tap(find.byKey(const ValueKey('work-round-collapse-bottom')));
    await tester.pump();
    expect(find.byKey(const ValueKey('work-round-scroll')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dismissing a recoverable error does not retry the operation', (
    tester,
  ) async {
    var dismissed = 0, retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecoveryNotice(
            error: StateError('connection failed'),
            onDismiss: () => dismissed++,
            onRetry: () async {
              retried++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('dismiss-recovery-notice')));
    expect(dismissed, 1);
    expect(retried, 0);
  });
  testWidgets('short popover viewport scrolls instead of overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 330,
            height: 100,
            child: ComposerPopoverFrame(
              title: '项目与执行位置',
              body: ListView(
                shrinkWrap: true,
                children: [
                  for (var i = 0; i < 10; i++) ListTile(title: Text('项目 $i')),
                ],
              ),
              footer: FilledButton(onPressed: () {}, child: const Text('完成')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(find.text('完成').hitTestable(), findsOneWidget);
  });

  testWidgets('work composer and project popup remain usable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(760, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(prefs),
        desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
        chatControllerProvider.overrideWith(_WorkChat.new),
        settingsControllerProvider.overrideWith(_Settings.new),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'NotoSansSC',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff735b9c),
            ),
          ),
          builder: (context, child) => RepaintBoundary(
            key: const ValueKey('ui-render'),
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.2)),
              child: child!,
            ),
          ),
          home: const ChatPage(desktopShell: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-workspace-bar')), findsOneWidget);
    expect(find.byType(ComposerPermissionControl), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'work');
    await tester.tap(find.text('项目 / 执行位置'));
    await tester.pumpAndSettle();
    expect(find.text('项目与执行位置').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'project-popup');
  });
  testWidgets(
    'work activity view throttles reorder and retains completed tasks',
    (tester) async {
      tester.view.physicalSize = const Size(450, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
          chatControllerProvider.overrideWith(_ActivityChat.new),
          settingsControllerProvider.overrideWith(_Settings.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ChatWorkspaceSidebar(desktopMode: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controller =
          container.read(chatControllerProvider.notifier) as _ActivityChat;
      controller.activity('a');
      await tester.pump();
      controller.activity('b');
      await tester.pump();
      await tester.tap(find.text('正在进行'));
      await tester.pump();
      List<String> order() => tester
          .widget<ConversationHistoryList>(
            find.byType(ConversationHistoryList).first,
          )
          .visible
          .map((c) => c.id)
          .toList();
      expect(order(), ['b', 'a']);
      controller.activity('a');
      await tester.pump(const Duration(milliseconds: 100));
      expect(order(), ['b', 'a']);
      await tester.pump(const Duration(seconds: 5));
      expect(order(), ['a', 'b']);
      controller.activity('a', complete: true);
      await tester.pump(const Duration(seconds: 5));
      expect(order(), contains('a'));
      expect(find.byTooltip('已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
