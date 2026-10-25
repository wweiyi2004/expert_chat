import 'dart:async';
import 'package:expert_chat/core/prototype_widgets.dart';
import 'dart:convert';
import 'package:expert_chat/features/shell/app_shell.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'dart:ui' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/features/workbench/workspace_workbench_page.dart';
import 'package:expert_chat/features/workbench/agents/work_agents_panel.dart';
import 'package:expert_chat/features/workbench/agents/work_agent_model_pool.dart';
import 'package:expert_chat/features/workbench/runtime/workspace_command_panel.dart';
import 'package:expert_chat/features/workbench/runtime/work_task_panel.dart';
import 'package:expert_chat/features/workbench/git/git_workspace_page.dart';
import 'package:expert_chat/features/chat/widgets/work_round_controls.dart';
import 'package:expert_chat/features/chat/widgets/work_session_footer.dart';
import 'package:expert_chat/domain/context/context_window_manager.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_rounds.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _TerminalChat extends ChatController {
  _TerminalChat(this.status);
  final SessionExecutionStatus status;
  @override
  Future<ChatState> build() async => ChatState(
    sessionCheckpoints: {
      'work': SessionExecutionCheckpoint(
        conversationId: 'work',
        status: status,
        updatedAt: DateTime(2026),
      ),
    },
  );
}

class _SteeringChat extends ChatController {
  final receipt = Completer<String>();
  int sends = 0;
  String? sentConversation;
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [
      Conversation(id: 'work', title: 'working', workMode: true),
      Conversation(id: 'other', title: 'other'),
    ],
    currentId: 'work',
  );
  @override
  Future<String> addWorkRequirement(String conversationId, String text) {
    sends++;
    sentConversation = conversationId;
    return receipt.future;
  }

  @override
  Future<void> selectConversation(String id) async {
    state = AsyncData(state.requireValue.copyWith(currentId: id));
  }
}

class _ResizeChat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [
      Conversation(
        id: 'work',
        title: 'resize work',
        workMode: true,
        messages: [ChatMessage(role: MessageRole.user, content: 'task')],
      ),
    ],
    currentId: 'work',
  );
}

class _MetricsChat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    contextReports: {
      'work': const ContextWindowReport(
        originalTokens: 900,
        sentTokens: 500,
        inputBudgetTokens: 1000,
        droppedMessages: 7,
        summaryInjected: true,
      ),
    },
  );
}

class _ReadyChanges extends WorkChanges {
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return const [];
  }
}

void main() {
  testWidgets(
    'three workbench sections retain terminal instances and category after closing',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(db.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            sharedPrefsProvider.overrideWithValue(prefs),
            conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
            desktopWorkspaceHostProvider.overrideWithValue(
              stub.createDesktopWorkspaceHost(),
            ),
            settingsControllerProvider.overrideWith(FakeSettings.new),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const Scaffold(
              body: WorkspaceWorkbenchPage(
                conversationId: 'work',
                embedded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WorkspaceWorkbenchPage)),
      );
      await container.read(settingsControllerProvider.future);
      await tester.pump();
      expect(find.byKey(const ValueKey('workbench-section-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('workbench-section-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('workbench-section-2')), findsOneWidget);
      await tester.tap(find.text('终端').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('新建终端'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(WorkspaceCommandPanel, skipOffstage: false),
        findsNWidgets(2),
      );
      await tester.tap(find.byKey(const ValueKey('workbench-section-0')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('workbench-instance-strip')),
        findsNothing,
        reason: '普通本轮改动不显示缓存终端的实例层',
      );
      expect(find.byType(InputChip), findsNothing);
      expect(find.byType(PrototypeTabStrip<int>), findsOneWidget);
      expect(find.byType(WorkspaceCommandPanel), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workbench-section-1')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(WorkspaceCommandPanel, skipOffstage: false),
        findsNWidgets(2),
      );
      await tester.tap(find.byTooltip('关闭终端').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(WorkspaceCommandPanel, skipOffstage: false),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('关闭终端').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(WorkspaceCommandPanel, skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('workbench-instance-strip')),
        findsNothing,
      );
      expect(find.byType(WorkTaskPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workbench-section-2')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('子代理'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester
            .widget<WorkAgentsPanel>(find.byType(WorkAgentsPanel))
            .showConfiguration,
        false,
      );
      expect(
        const WorkAgentsPanel(conversationId: 'work').showConfiguration,
        true,
      );
      expect(find.text('子代理限制').hitTestable(), findsNothing);
      expect(find.text('限制与预算'), findsNothing);
      expect(find.text('子代理可用模型'), findsNothing);
      expect(
        find.byType(WorkAgentModelPoolSettings, skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byType(WorkAgentLimitsEditor, skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'round strip pause, resume, extension and steering call real state',
    (tester) async {
      var steering = 0;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(workRoundsProvider.notifier)
          .start(
            'work',
            'run',
            const SessionPolicy(toolRounds: 12, roundExtension: 5),
          );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: WorkRoundControls(
                conversationId: 'work',
                onSteer: () => steering++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('本轮后暂停'));
      await tester.pump();
      expect(
        container.read(workRoundsProvider)['work']!.pauseRequested,
        isTrue,
      );
      await tester.tap(find.text('取消待暂停'));
      await tester.pump();
      expect(
        container.read(workRoundsProvider)['work']!.pauseRequested,
        isFalse,
      );
      await tester.tap(find.byTooltip('更多轮次操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+5 轮'));
      await tester.pump();
      expect(container.read(workRoundsProvider)['work']!.limit, 17);
      await tester.tap(find.text('补充任务'));
      expect(steering, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in [
    (SessionExecutionStatus.failed, '执行失败'),
    (SessionExecutionStatus.cancelled, '已停止'),
    (SessionExecutionStatus.interrupted, '已中断'),
  ]) {
    testWidgets('round strip preserves terminal status ${entry.$2}', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          chatControllerProvider.overrideWith(() => _TerminalChat(entry.$1)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      container
          .read(workRoundsProvider.notifier)
          .start('work', 'run', const SessionPolicy());
      container
          .read(workRoundsProvider.notifier)
          .update('work', 'run', (p) => p.copyWith(active: false));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: WorkRoundControls(conversationId: 'work')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(entry.$2), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
    });
  }

  testWidgets(
    'steering uses one real channel request and preserves another conversation draft',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final chat = _SteeringChat();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          chatControllerProvider.overrideWith(() => chat),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      tester.view.physicalSize = const Size(790, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await container.read(chatControllerProvider.future);
      container
          .read(workRoundsProvider.notifier)
          .start('work', 'run', const SessionPolicy());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const ChatPage(desktopShell: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多轮次操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补充任务'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('补充任务 · 不会打断当前轮'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('composer-text-field')),
        'first requirement',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-send-button')));
      await tester.tap(find.byKey(const ValueKey('composer-send-button')));
      await tester.pump();
      expect(chat.sends, 1);
      expect(chat.sentConversation, 'work');
      await chat.selectConversation('other');
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('composer-text-field')),
        'keep other draft',
      );
      chat.receipt.complete('receipt-1');
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('composer-text-field')),
            )
            .controller!
            .text,
        'keep other draft',
      );
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('导出 Markdown').hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workbench divider supports keyboard reset persistence clamp and mobile sheet',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          chatControllerProvider.overrideWith(_ResizeChat.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: const ChatPage(desktopShell: true),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final panel = find.byType(WorkspaceWorkbenchPage);
      final handle = find.byKey(const ValueKey('workbench-resize-handle'));
      expect(tester.getSize(panel).width, 560);
      expect(
        tester
            .getSemantics(handle)
            .getSemanticsData()
            .hasAction(SemanticsAction.increase),
        isTrue,
      );
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(tester.getSize(panel).width, 576);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(tester.getSize(panel).width, 512);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(tester.getSize(panel).width, 340);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(tester.getSize(panel).width, 850);
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(panel).width, 560);
      await tester.tap(find.byTooltip('放大工作台'));
      await tester.pump();
      expect(tester.getSize(panel).width, 1270);
      await tester.drag(handle, const Offset(30, 0));
      await tester.pump();
      expect(find.byTooltip('放大工作台'), findsOneWidget);
      expect(tester.getSize(panel).width, lessThanOrEqualTo(850));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .ui
            .workbenchWidth,
        560,
      );
      expect(jsonDecode(prefs.getString('uiPrefs')!)['workbenchWidth'], 560);
      tester.view.physicalSize = const Size(900, 900);
      await tester.pump();
      expect(tester.getSize(panel).width, 470);
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .ui
            .workbenchWidth,
        560,
      );
      tester.view.physicalSize = const Size(839, 900);
      await tester.pump();
      expect(panel, findsNothing);
      await tester.tap(find.byTooltip('打开工作台'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ListTile, '改动'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(panel).height, closeTo(900 * .78, 1));
      await tester.tap(find.byTooltip('收起工作台'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      tester.view.physicalSize = const Size(819, 900);
      await tester.pump();
      expect(panel, findsNothing);
      await tester.tap(find.byTooltip('打开工作台'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ListTile, '改动'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.getSize(panel).height, closeTo(900 * .78, 1));
      expect(tester.getBottomLeft(panel).dy, lessThanOrEqualTo(900));
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('usage ring uses actual per-conversation context denominator', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          chatControllerProvider.overrideWith(_MetricsChat.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: WorkSessionFooter(conversationId: 'work', busy: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      .5,
    );
    await tester.tap(find.byKey(const ValueKey('work-context-details')));
    await tester.pumpAndSettle();
    expect(find.text('上下文 500 / 1.0K · 50%'), findsOneWidget);
    expect(find.text('丢弃消息 7 条 · 已注入摘要'), findsOneWidget);
    expect(find.text('缓存命中：待统计'), findsOneWidget);
    expect(find.textContaining('费用：未提供'), findsOneWidget);
  });

  testWidgets(
    '1000 window with sidebar opens undocked workbench as full page',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          chatControllerProvider.overrideWith(_ResizeChat.new),
          workChangesProvider.overrideWith(_ReadyChanges.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceWorkbenchPage), findsNothing);
      await tester.tap(find.byTooltip('打开工作台'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      final panel = find.byType(WorkspaceWorkbenchPage);
      expect(tester.widget<WorkspaceWorkbenchPage>(panel).embedded, isFalse);
      expect(tester.getSize(panel).width, 1000);
      expect(tester.getSize(panel).height, 900);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'HTML chat header and composer use measured pane geometry without duplicate workbench tabs',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          chatControllerProvider.overrideWith(_ResizeChat.new),
          workChangesProvider.overrideWith(_ReadyChanges.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ChatPage(desktopShell: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final header = tester.getRect(
        find.byKey(const ValueKey('html-chat-header')),
      );
      final mode = tester.getRect(
        find.byKey(const ValueKey('chat-work-mode-switch')),
      );
      final input = tester.getRect(
        find.byKey(const ValueKey('composer-input-box')),
      );
      expect(header.height, 52);
      expect(mode.center.dx, closeTo(header.center.dx, 1));
      expect(input.width, 700);
      expect(input.height, lessThanOrEqualTo(90));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('composer-text-field')))
            .height,
        lessThanOrEqualTo(30),
      );
      expect(find.byType(ChoiceChip), findsNothing);
      expect(
        find.byKey(const ValueKey('workbench-instance-strip')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Git initial view opens real Git section', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GitWorkspacePage(
          workspaceName: 'test',
          rootPath: '.',
          initialView: 1,
          gitAvailable: false,
          callFileTool: (_, _) async => '{"entries":[]}',
          authorizeGit: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Git 改动'), findsOneWidget);
    await tester.tap(find.text('Git 改动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交关系图').last);
    await tester.pumpAndSettle();
    expect(find.text('提交关系图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
