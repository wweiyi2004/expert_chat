import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/ui_prefs.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart'
    as desktop_stub;
import 'package:expert_chat/features/shell/app_shell.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/features/shell/automation_page.dart';
import 'package:expert_chat/features/shell/conversation_return_scope.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:expert_chat/state/work_rounds.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart'
    show FakeSettings, FakeLlmProvider, InMemoryRepo, InMemoryLibraryFileStore;

final _palette = ColorThemePref.fromWire(
  const String.fromEnvironment('VISUAL_PALETTE', defaultValue: 'minimal'),
);

const _automationFixtures = bool.fromEnvironment('AUTOMATION_FIXTURES');

class _AutomationAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({
      'automations': [
        {
          'id': 'nightly_quality_check',
          'trigger': 'schedule',
          'intervalSeconds': 86400,
          'goal': '运行项目回归测试并生成可复核的交付报告',
          'path': 'D:/work/quality-verification-project',
          'policy': 'request',
          'paused': false,
          'lastRun': '2026-10-24 23:00 · 已完成',
        },
      ],
      'environments': [],
      'allowedPolicies': ['request'],
    }),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  void close({bool force = false}) {}
}

const _agentFixtures = bool.fromEnvironment('AGENT_FIXTURES');

class _Agents extends WorkAgentRuntime {
  late final _preview = [
    for (var i = 0; i < 3; i++)
      WorkAgentRecord(
          id: 'agent-$i',
          conversationId: 'work',
          taskId: 'preview',
          task: ['检查界面布局与功能入口', '等待模型可用后执行代码审查', '完成配色与兼容验证'][i],
          depth: 1,
          limits: const WorkAgentLimits(),
          environment: WorkAgentEnvironment(
            provider: FakeLlmProvider(const []),
            config: const LlmConfig(baseUrl: '', apiKey: '', model: 'fixture'),
            tools: const [],
            executeTool: (_, _, _, _) async => '',
            resolveModel: (_, config) async => config,
          ),
        )
        ..model = 'deepseek-v4-flash'
        ..status = [
          WorkAgentStatus.running,
          WorkAgentStatus.queued,
          WorkAgentStatus.completed,
        ][i]
        ..activity = ['执行中', '排队', '完成'][i],
  ];
  @override
  List<WorkAgentRecord> get records => _preview;
  @override
  WorkAgentRecord? record(String id) =>
      _preview.where((a) => a.id == id).firstOrNull;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async =>
      (await super.build()).copyWith(ui: UiPrefs(colorTheme: _palette));
}

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [
      Conversation(
        id: 'work',
        title: '界面改版 · 实施与验收',
        workMode: true,
        messages: [
          ChatMessage(
            id: 'u',
            role: MessageRole.user,
            content: '请检查项目并交付新版界面，保留全部现有功能。',
          ),
          ChatMessage(
            id: 'a',
            parentId: 'u',
            role: MessageRole.assistant,
            content: '已经整理本轮改动。交付文件可以在工作台预览；下一步运行验证前，请确认下面的命令。',
          ),
        ],
        activeChildren: {'': 'u', 'u': 'a'},
      ),
      Conversation(id: 'chat', title: '论文资料整理', workMode: false),
    ],
  );
}

class _Approvals extends WorkApprovals {
  @override
  List<PendingWorkApproval> build() => [
    PendingWorkApproval(
      id: 'approval',
      conversationId: 'work',
      tool: 'workspace_shell',
      target: '默认工作区',
      reason: '运行本机项目的验证命令，不修改用户文件。',
      arguments: '{"command":"flutter test --no-pub","timeout_ms":120000}',
    ),
  ];
}

class _Changes extends WorkChanges {
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return [
      WorkFileChange(
        id: 'delivery',
        conversationId: 'work',
        assistantId: 'a',
        target: '{"kind":"local","root":"isolated-preview"}',
        scope: '.',
        path: 'lib/features/chat/widgets/execution_status_indicator.dart',
        before: '旧界面',
        after: '新界面',
        beforeHash: 'before',
        afterHash: 'after',
        deliveryHash: 'after',
        updatedAt: DateTime(2026, 10, 25),
      ),
    ];
  }
}

class _Rounds extends WorkRounds {
  @override
  Map<String, WorkRoundProgress> build() => {
    'work': const WorkRoundProgress(
      runId: 'preview',
      limit: 12,
      step: 5,
      reviewAhead: 1,
      autoExtend: false,
      used: 4,
      pauseRequested: true,
      paused: true,
    ),
  };
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final error = tester.takeException();
  if (!const bool.fromEnvironment('RENDER_REDESIGN')) {
    expect(error, isNull, reason: name);
    return;
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('redesign-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    const directory = String.fromEnvironment(
      'REDESIGN_OUTPUT',
      defaultValue: 'output/redesign-review/screenshots',
    );
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
  expect(error, isNull, reason: name);
}

void _reachable(WidgetTester tester, Finder finder, double bottom) {
  expect(finder.hitTestable(), findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(bottom + 1));
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(tester.view.physicalSize.width + 1));
}

void main() {
  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Expert Chat',
      packageName: 'com.wweiyi.expert_chat',
      version: '3.8.1',
      buildNumber: '4113',
      buildSignature: '',
    );
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final mono = File('C:/Windows/Fonts/consola.ttf');
    if (await mono.exists()) {
      await (FontLoader('monospace')..addFont(
            Future.value(ByteData.sublistView(await mono.readAsBytes())),
          ))
          .load();
    }
  });
  for (final width in [360.0, 390.0, 1280.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('complete UI at $width ${dark ? 'dark' : 'light'}', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, width < 840 ? 900 : 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        FlutterSecureStorage.setMockInitialValues(
          _automationFixtures
              ? {
                  'remote_host_computers_v1': jsonEncode([
                    {
                      'url': 'https://fixture-computer.example',
                      'token': 'fixture-only',
                      'connectionId': 'preview',
                    },
                  ]),
                }
              : {},
        );
        SharedPreferences.setMockInitialValues({
          'workHooks.v1': jsonEncode([
            {
              'id': 'preview-hook',
              'conversationId': 'work',
              'root':
                  'E:/isolated-fixtures/expert-chat-ui-redesign/long-project-directory',
              'watchPath': 'lib/**/*.dart',
              'command':
                  'flutter test --no-pub --reporter expanded test/widget_regression_test.dart',
              'enabled': true,
              'debounceMs': 800,
            },
          ]),
        });
        final prefs = await SharedPreferences.getInstance();
        final temporary = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('expert-redesign-visual-'),
        ))!;
        final oldPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(temporary.path);
        final db = AppDatabase(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            automationHttpClientFactoryProvider.overrideWithValue(
              () => Dio()..httpClientAdapter = _AutomationAdapter(),
            ),
            appDatabaseProvider.overrideWithValue(db),
            sharedPrefsProvider.overrideWithValue(prefs),
            settingsControllerProvider.overrideWith(_Settings.new),
            chatControllerProvider.overrideWith(_Chat.new),
            conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
            libraryFileStoreProvider.overrideWithValue(
              InMemoryLibraryFileStore(),
            ),
            desktopWorkspaceHostProvider.overrideWithValue(
              desktop_stub.createDesktopWorkspaceHost(),
            ),
            if (_agentFixtures)
              workAgentsProvider.overrideWith((ref) {
                final runtime = _Agents();
                ref.onDispose(runtime.dispose);
                return runtime;
              }),
            workApprovalsProvider.overrideWith(_Approvals.new),
            workChangesProvider.overrideWith(_Changes.new),
            workRoundsProvider.overrideWith(_Rounds.new),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close();
          PathProviderPlatform.instance = oldPaths;
          await temporary.delete(recursive: true);
        });
        await container.read(chatControllerProvider.future);
        await container.read(settingsControllerProvider.future);
        final navigatorKey = GlobalKey<NavigatorState>();
        final observer = ConversationRouteObserver();
        final tag =
            '${_automationFixtures ? 'automation-fixture-' : ''}${_palette.isArt ? '${_palette.name}-' : ''}${width.toInt()}-${dark ? 'dark' : 'light'}';
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: navigatorKey,
              navigatorObservers: [observer],
              theme: AppTheme.light(UiPrefs(colorTheme: _palette)),
              darkTheme: AppTheme.dark(UiPrefs(colorTheme: _palette)),
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: RepaintBoundary(
                  key: const ValueKey('redesign-render'),
                  child: ConversationReturnScope(
                    navigatorKey: navigatorKey,
                    observer: observer,
                    child: child!,
                  ),
                ),
              ),
              home: const AppShell(),
            ),
          ),
        );
        await _pump(tester);
        await _capture(tester, '$tag-chat');
        if (width >= 840) {
          final label = tester.getRect(
            find.byKey(const ValueKey('sidebar-work-section-label')),
          );
          final folder = tester.getRect(
            find.byKey(const ValueKey('sidebar-manage-locations')),
          );
          final menu = tester.getRect(
            find.byKey(const ValueKey('sidebar-work-filter')),
          );
          expect(label.center.dy, closeTo(folder.center.dy, .1));
          expect(label.center.dy, closeTo(menu.center.dy, .1));
        }
        if (width < 840) {
          _reachable(
            tester,
            find.byKey(const ValueKey('composer-text-field')),
            900,
          );
          _reachable(tester, find.byTooltip('语音输入'), 900);
          _reachable(tester, find.text('批准这一次'), 900);
          _reachable(tester, find.text('拒绝'), 900);
          await tester.enterText(
            find.byKey(const ValueKey('composer-text-field')),
            '补充验收要求',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await _pump(tester);
          _reachable(
            tester,
            find.byKey(const ValueKey('composer-text-field')),
            600,
          );
          _reachable(tester, find.byTooltip('发送'), 600);
          _reachable(tester, find.text('批准这一次'), 600);
          _reachable(tester, find.text('拒绝'), 600);
          await _capture(tester, '$tag-keyboard');
          tester.view.viewInsets = const FakeViewPadding();
          await tester.enterText(
            find.byKey(const ValueKey('composer-text-field')),
            '',
          );
          await _pump(tester);
          final drawer = find.byType(DrawerButton).hitTestable();
          expect(drawer, findsOneWidget);
          if (drawer.evaluate().isNotEmpty) {
            await tester.tap(drawer.first);
            await _pump(tester);
            await _capture(tester, '$tag-sidebar');
            await tester.binding.handlePopRoute();
            await _pump(tester);
          }
          final workbench = find.byTooltip('打开工作台').hitTestable();
          expect(workbench, findsOneWidget);
          if (workbench.evaluate().isNotEmpty) {
            await tester.tap(workbench.first);
            await _pump(tester);
            final changes = find.text('改动').hitTestable();
            if (changes.evaluate().isNotEmpty) {
              await tester.tap(changes.first);
              await _pump(tester);
            }
            _reachable(tester, find.byTooltip('收起工作台'), 900);
            await _capture(tester, '$tag-workbench');
            if (_agentFixtures) {
              await tester.tap(
                find.byKey(const ValueKey('workbench-section-2')),
              );
              await _pump(tester);
              final agents = find.widgetWithText(ActionChip, '子代理');
              expect(agents, findsOneWidget);
              if (agents.evaluate().isNotEmpty) {
                await tester.tap(agents);
                await _pump(tester);
              }
              await _capture(tester, '$tag-agents');
            }
            await tester.binding.handlePopRoute();
            await _pump(tester);
          }
        }
        for (final tab in [
          ShellTab.automation,
          ShellTab.resources,
          ShellTab.settings,
        ]) {
          container.read(shellTabProvider.notifier).set(tab);
          await _pump(tester);
          if (tab == ShellTab.automation) {
            // Pair storage -> connection probe -> panel fetch span three frames.
            await _pump(tester);
            await _pump(tester);
          }
          if (width < 840) {
            expect(
              find.text('回到对话').hitTestable(),
              findsOneWidget,
              reason: '${tab.name} keeps the return action visible',
            );
          } else {
            final surface = tester.getRect(
              find.byKey(const ValueKey('application-surface')),
            );
            expect(surface.left, greaterThan(0));
            expect(surface.right, lessThan(width));
            expect(surface.top, greaterThan(0));
            expect(surface.bottom, lessThan(tester.view.physicalSize.height));
            expect(find.byTooltip('关闭窗口').hitTestable(), findsOneWidget);
          }
          if (tab == ShellTab.automation) {
            expect(find.textContaining('无法读取已配对电脑'), findsNothing);
            expect(
              find.textContaining('widget_regression_test.dart'),
              findsOneWidget,
            );
            if (_automationFixtures) {
              expect(find.text('nightly_quality_check'), findsOneWidget);
            }
          }
          await _capture(tester, '$tag-${tab.name}');
        }
        for (final category in ['模型', '助手与技能', '连接', '多媒体', '外观与数据']) {
          final item = find.text(category).hitTestable();
          expect(
            item,
            findsWidgets,
            reason: 'Settings category $category remains reachable',
          );
          if (item.evaluate().isNotEmpty) {
            await tester.tap(item.first);
            await _pump(tester);
            await _capture(tester, '$tag-settings-$category');
            if (category == '助手与技能' || category == '外观与数据') {
              final target = category == '助手与技能' ? '子代理限制' : '导出 API 配置';
              final scroll = find
                  .descendant(
                    of: find.byWidgetPredicate(
                      (w) =>
                          w is ListView &&
                          w.key is ValueKey<String> &&
                          (w.key! as ValueKey<String>).value.startsWith(
                            'settings-',
                          ),
                    ),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              // The large instruction editor has its own vertical scrollable;
              // drive the settings list directly instead of dragging its child.
              for (
                var step = 0;
                step < 100 &&
                    find.text(target).hitTestable().evaluate().isEmpty;
                step++
              ) {
                final position = tester.state<ScrollableState>(scroll).position;
                position.jumpTo(
                  (position.pixels + 350).clamp(0, position.maxScrollExtent),
                );
                await _pump(tester);
              }
              await tester.ensureVisible(find.text(target));
              await _pump(tester);
              await _capture(tester, '$tag-settings-$category-actions');
              if (category == '外观与数据') {
                await tester.scrollUntilVisible(
                  find.text('关于与更新'),
                  250,
                  scrollable: scroll,
                );
                await _pump(tester);
                await _capture(tester, '$tag-settings-$category-about');
              }
            }
            if (width < 840) {
              await tester.binding.handlePopRoute();
              await _pump(tester);
            }
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
