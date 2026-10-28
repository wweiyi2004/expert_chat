import 'package:expert_chat/core/prototype_widgets.dart';
import 'dart:async';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/shell/conversation_return_scope.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/features/chat/widgets/sidebar_reorder_motion.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/conversation_attention.dart';
import 'package:expert_chat/state/conversation_activity.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/remote/remote_automation_panel.dart';
import 'package:expert_chat/features/shell/automation_page.dart';
import 'package:expert_chat/state/work_processes.dart' show workHooksProvider;
import 'package:expert_chat/domain/workbench/processes/work_hook_runtime.dart';
import 'package:expert_chat/domain/workbench/processes/work_process_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'widget_test.dart' show FakeLlmProvider;

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [Conversation(id: 'kept', title: '保留的会话')],
    currentId: 'kept',
  );
  void reply() {
    final c = state.requireValue.current!;
    state = AsyncData(
      state.requireValue.copyWith(
        conversations: [
          c.copyWith(
            messages: [
              ChatMessage(role: MessageRole.assistant, content: '新回复'),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Future<void> selectConversation(String id) async {
    state = AsyncData(state.requireValue.copyWith(currentId: id));
  }
}

class _TaskChat extends _Chat {
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [
      Conversation(id: 'kept', title: '原工作会话', workMode: true),
      Conversation(id: 'other', title: '另一个运行任务', workMode: true),
    ],
    currentId: 'kept',
    runningConversationIds: {'other'},
  );
}

class _Agents extends WorkAgentRuntime {
  final items = <WorkAgentRecord>[];
  @override
  List<WorkAgentRecord> get records => items;
  void update() => notifyListeners();
}

void main() {
  testWidgets(
    'automation keeps long local command and path readable at 360 with large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final process = WorkProcessRuntime();
      final hooks = WorkHookRuntime(
        processes: process,
        definitions: [
          const WorkHookDefinition(
            id: 'long_hook',
            conversationId: 'kept',
            root:
                'E:/Work/very-long-project-directory-for-verification-and-deliveries',
            command:
                'flutter test --reporter expanded test/all_critical_regressions_and_delivery_evidence_test.dart',
          ),
        ],
        persist: (_) async {},
        changeFeed: (_) => const Stream.empty(),
      );
      addTearDown(hooks.dispose);
      addTearDown(process.dispose);
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chatControllerProvider.overrideWith(_TaskChat.new),
          workHooksProvider.overrideWithValue(hooks),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.24)),
              child: child!,
            ),
            home: const AutomationPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('立即运行'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('立即运行'));
      await tester.pumpAndSettle();
      expect(find.text('沿用原会话权限'), findsOneWidget);
      expect(find.byTooltip('管理'), findsOneWidget);
      expect(find.byType(PrototypeSwitch), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manual remote run blocks double clicks and retries unknown outcomes with same identity',
    (tester) async {
      final pending = <String, String>{};
      final events = <String>[];
      final gate = Completer<void>();
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      Future<dynamic> request(String path, {Map<String, dynamic>? body}) async {
        if (path.startsWith('webhooks/')) {
          events.add(body!['eventId'] as String);
          if (events.length == 1) await gate.future;
        }
        return {
          'automations': [
            {
              'id': 'rule',
              'trigger': 'schedule',
              'goal': 'Configured task',
              'policy': 'request',
            },
          ],
          'environments': [],
        };
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<int>(
                valueListenable: revision,
                builder: (_, value, _) => RemoteAutomationPanel(
                  key: ValueKey(value),
                  request: request,
                  manualEventIds: pending,
                  initiallyExpanded: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('立即运行'));
      await tester.pump();
      await tester.tap(find.byTooltip('立即运行'));
      await tester.pump();
      expect(events, hasLength(1));
      gate.completeError(
        StateError('connection lost after host accepted task'),
      );
      await tester.pumpAndSettle();
      expect(pending, hasLength(1));
      revision.value++;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('立即运行'));
      await tester.pumpAndSettle();
      expect(events, hasLength(2));
      expect(events[1], events[0]);
      expect(pending, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'read completed task is inactive while detached child remains active',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final agents = _Agents();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chatControllerProvider.overrideWith(_Chat.new),
          workAgentsProvider.overrideWithValue(agents),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(agents.dispose);
      await container.read(chatControllerProvider.future);
      final subscription = container.listen(
        conversationActiveIdsProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(container.read(conversationActiveIdsProvider), isEmpty);
      final child = WorkAgentRecord(
        id: 'child',
        conversationId: 'other',
        taskId: 't',
        task: 'detached child',
        depth: 1,
        limits: const WorkAgentLimits(),
        environment: WorkAgentEnvironment(
          provider: FakeLlmProvider(const []),
          config: const LlmConfig(
            baseUrl: 'https://test.invalid',
            apiKey: 'test',
            model: 'test',
          ),
          tools: const [],
          executeTool: (_, _, _, _) async => 'approved',
          resolveModel: (_, parent) async => parent,
        ),
      );
      agents.items.add(child);
      agents.update();
      expect(container.read(conversationActiveIdsProvider), contains('other'));
      child.status = WorkAgentStatus.completed;
      agents.update();
      expect(container.read(conversationActiveIdsProvider), isEmpty);
    },
  );

  testWidgets(
    'remote automation cards expose real metadata enable and trigger actions',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      var paused = false;
      Future<dynamic> request(String path, {Map<String, dynamic>? body}) async {
        calls.add(path);
        if (body != null && path == 'automation') {
          paused = (body['item'] as Map)['paused'] == true;
        }
        return {
          'automations': [
            {
              'id': 'nightly_checks',
              'trigger': 'schedule',
              'goal': '运行已配置的完整检查',
              'policy': 'request',
              'lastRun': '2026-10-25T10:00:00Z',
              'paused': paused,
            },
          ],
          'environments': [],
          'allowedPolicies': ['request'],
        };
      }

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.24)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RemoteAutomationPanel(
                request: request,
                hostLabel: 'very-long-production-build-host.example.invalid',
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('定时'), findsOneWidget);
      expect(
        find.text('远程 · very-long-production-build-host.example.invalid'),
        findsOneWidget,
      );
      expect(find.text('请求批准'), findsOneWidget);
      expect(find.textContaining('2026-10-25'), findsOneWidget);
      await tester.tap(find.byTooltip('立即运行'));
      await tester.pumpAndSettle();
      expect(calls, contains('webhooks/nightly_checks'));
      await tester.tap(find.byType(PrototypeSwitch));
      await tester.pumpAndSettle();
      expect(paused, isTrue);
      await tester.tap(find.textContaining('nightly_checks'));
      await tester.pumpAndSettle();
      expect(find.text('自动化触发器'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'scroll-only rebuild does not animate rows and reduced motion stops tickers',
    (tester) async {
      final scroll = ScrollController();
      final update = ValueNotifier(0);
      final reduce = ValueNotifier(false);
      addTearDown(scroll.dispose);
      addTearDown(update.dispose);
      addTearDown(reduce.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: reduce,
            builder: (context, reduced, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: ValueListenableBuilder<int>(
                valueListenable: update,
                builder: (_, mode, _) => ListView(
                  controller: scroll,
                  children: [
                    for (final i
                        in mode == 2
                            ? List.generate(20, (i) => 19 - i)
                            : List.generate(20, (i) => i))
                      SidebarReorderMotion(
                        key: ValueKey('motion-$i'),
                        child: SizedBox(
                          height: 60,
                          child: Text(
                            'row $i · $mode',
                            key: ValueKey('row-$i'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      scroll.jumpTo(200);
      await tester.pump();
      final before = tester.getTopLeft(find.byKey(const ValueKey('row-5'))).dy;
      update.value = 1;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const ValueKey('row-5'))).dy, before);
      expect(tester.binding.transientCallbackCount, 0);
      update.value = 2;
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      reduce.value = true;
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'deep route task menu and tooltip use the real overlay and select original task',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chatControllerProvider.overrideWith(_TaskChat.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      container.read(shellTabProvider.notifier).set(ShellTab.settings);
      final key = GlobalKey<NavigatorState>();
      final observer = ConversationRouteObserver();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: key,
            navigatorObservers: [observer],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: ConversationReturnScope(
                navigatorKey: key,
                observer: observer,
                child: child!,
              ),
            ),
            home: const Scaffold(body: Text('设置根页')),
          ),
        ),
      );
      await tester.pump();
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('深层模型编辑器')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('另有 1 个任务 ▾'));
      await tester.pumpAndSettle();
      expect(find.text('另一个运行任务'), findsOneWidget);
      tester
          .state<TooltipState>(find.byType(Tooltip).last)
          .ensureTooltipVisible();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('另一个运行任务'));
      await tester.pumpAndSettle();
      expect(container.read(shellTabProvider), ShellTab.chat);
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'other',
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'attention starts seen and only clears replies when chat route is visible',
    () async {
      final container = ProviderContainer(
        overrides: [chatControllerProvider.overrideWith(_Chat.new)],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      final subscription = container.listen(
        conversationAttentionProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      expect(container.read(conversationAttentionProvider), isEmpty);
      container.read(shellTabProvider.notifier).set(ShellTab.settings);
      container.read(chatControllerProvider.notifier) as _Chat;
      (container.read(chatControllerProvider.notifier) as _Chat).reply();
      expect(container.read(conversationAttentionProvider), contains('kept'));
      container.read(conversationRouteVisibleProvider.notifier).set(false);
      container.read(shellTabProvider.notifier).set(ShellTab.chat);
      expect(container.read(conversationAttentionProvider), contains('kept'));
      container.read(conversationRouteVisibleProvider.notifier).set(true);
      expect(container.read(conversationAttentionProvider), isEmpty);
    },
  );
  test('primary navigation has the four agreed destinations', () {
    expect(ShellTab.navigation, [
      ShellTab.chat,
      ShellTab.automation,
      ShellTab.resources,
      ShellTab.settings,
    ]);
    expect(ShellTab.studio.navigationTab, ShellTab.resources);
    expect(ShellTab.terminal.navigationTab, ShellTab.settings);
  });

  test(
    'manual hook retains binding, disable, running and settle guards',
    () async {
      final process = WorkProcessRuntime();
      final feed = StreamController<String>.broadcast();
      final hooks = WorkHookRuntime(
        processes: process,
        definitions: [
          const WorkHookDefinition(
            id: 'hook',
            conversationId: 'c',
            root: '/granted',
            command: 'fixed',
          ),
        ],
        persist: (_) async {},
        changeFeed: (_) => feed.stream,
      );
      addTearDown(() async {
        hooks.dispose();
        process.dispose();
        await feed.close();
      });
      await expectLater(hooks.runNow('hook'), throwsStateError);
      var launched = 0;
      final done = Completer<WorkProcessResult>();
      hooks.bind(
        conversationId: 'c',
        root: '/granted',
        launch: (d) async {
          launched++;
          expect(d.command, 'fixed');
          return process.start(
            conversationId: 'c',
            taskId: 't',
            command: d.command,
            target: d.root,
            execute: (_, _) => done.future,
          );
        },
      );
      await hooks.save(
        hooks.records.single.definition.copyWith(enabled: false),
      );
      await expectLater(hooks.runNow('hook'), throwsStateError);
      await hooks.save(hooks.records.single.definition.copyWith(enabled: true));
      await hooks.runNow('hook');
      expect(launched, 1);
      await expectLater(hooks.runNow('hook'), throwsStateError);
      final event = process.events.first;
      done.complete(const WorkProcessResult(exitCode: 0));
      await event;
      await expectLater(hooks.runNow('hook'), throwsStateError);
      expect(launched, 1);
    },
  );

  testWidgets(
    'deep settings route keeps return bar and Esc protects editor and dialog',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chatControllerProvider.overrideWith(_Chat.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      container.read(shellTabProvider.notifier).set(ShellTab.settings);
      final key = GlobalKey<NavigatorState>();
      final observer = ConversationRouteObserver();
      final draft = TextEditingController(text: '保留的草稿');
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: key,
            navigatorObservers: [observer],
            builder: (context, child) => ConversationReturnScope(
              navigatorKey: key,
              observer: observer,
              child: child!,
            ),
            home: Scaffold(body: TextField(controller: draft)),
          ),
        ),
      );
      await tester.pump();
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('模型编辑器')),
            body: Column(
              children: [
                const TextField(key: ValueKey('editor')),
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const AlertDialog(title: Text('模态确认')),
                    ),
                    child: const Text('打开确认'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('回到对话'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(container.read(shellTabProvider), ShellTab.settings);
      await tester.tap(find.text('打开确认'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('回到对话'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(shellTabProvider), ShellTab.settings);
      FocusManager.instance.primaryFocus?.unfocus();
      final blocked = ValueNotifier(true);
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => ValueListenableBuilder<bool>(
            valueListenable: blocked,
            builder: (_, value, _) => PopScope(
              canPop: !value,
              child: const Scaffold(body: Text('保存中的编辑器')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('回到对话'));
      await tester.pumpAndSettle();
      expect(find.text('保存中的编辑器'), findsOneWidget);
      expect(container.read(shellTabProvider), ShellTab.settings);
      blocked.value = false;
      await tester.pump();
      await tester.tap(find.byTooltip('回到对话'));
      await tester.pumpAndSettle();
      expect(container.read(shellTabProvider), ShellTab.chat);
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'kept',
      );
      expect(draft.text, '保留的草稿');
      blocked.dispose();
    },
  );
}
