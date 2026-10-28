import 'dart:io';
import 'dart:ui' as ui;
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/workbench/runtime/task_control_panel.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/task_acceptance_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

class _Chat extends ChatController {
  int reviewed = 0;
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'c',
    conversations: [Conversation(id: 'c', title: '工作', workMode: true)],
    sessionCheckpoints: {
      'c': SessionExecutionCheckpoint(
        conversationId: 'c',
        status: SessionExecutionStatus.completed,
        updatedAt: DateTime(2026),
        phase: '本轮答复已结束',
        taskState: {
          'rootId': 'task',
          'budget': {'toolCalls': 3, 'searches': 1, 'elapsedMs': 9000},
          'repositorySources': {
            'main': {
              'sources': [
                {
                  'path': '/project/AGENTS.md',
                  'scope': '/project',
                  'kind': 'rule',
                  'hash': 'a' * 64,
                },
              ],
              'warnings': [],
              'skills': [
                {'name': 'review', 'description': '代码审查'},
              ],
            },
          },
        },
      ),
    },
  );
  @override
  Future<bool> verifyAndAcceptTask(String conversationId) async {
    reviewed++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        chatControllerProvider.overrideWith(_Chat.new),
      ],
    );
    await c.read(chatControllerProvider.future);
    await c
        .read(taskAcceptanceProvider.notifier)
        .freeze(
          'task',
          AcceptanceCriteria(description: '原有条件'),
          conversationId: 'c',
        );
    await c.read(taskAcceptanceProvider.notifier).update('task', (t) {
      t.replyComplete = true;
      t.toolsComplete = true;
    });
    return c;
  }

  testWidgets(
    'criteria are future-task drafts and original evidence remains frozen',
    (tester) async {
      final c = await container();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: TaskAdvancedOptions(conversationId: 'c')),
          ),
        ),
      );
      await tester.tap(find.text('高级任务选项'));
      await tester.pumpAndSettle();
      expect(find.text('固定任务约束'), findsOneWidget);
      await tester.tap(find.text('下一任务的验收条件'));
      await tester.pumpAndSettle();
      final description = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '验收说明',
      );
      final commands = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '必须通过的检查命令（每行一条）',
      );
      await tester.enterText(description, '交付指定文件并通过检查');
      await tester.enterText(commands, 'flutter test\nflutter analyze');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(
        c
            .read(taskAcceptanceProvider.notifier)
            .draftCriteriaForConversation('c')
            .checkIds,
        ['flutter test', 'flutter analyze'],
      );
      expect(
        c.read(taskAcceptanceProvider)['task']!.criteria.description,
        '原有条件',
      );
      expect(
        c.read(sharedPrefsProvider).getString(TaskAcceptanceStore.storageKey),
        contains('flutter test'),
      );
      await tester.tap(find.text('已加载的仓库规则与技能'));
      await tester.pumpAndSettle();
      expect(find.textContaining('/project/AGENTS.md'), findsOneWidget);
      expect(find.textContaining(r'$review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'acceptance action invokes revalidation controller, not local approval',
    (tester) async {
      final c = await container();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: TaskControlPanel(conversationId: 'c')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('等待验收'), findsOneWidget);
      await tester.tap(find.text('核验产物并确认通过'));
      await tester.pumpAndSettle();
      expect((c.read(chatControllerProvider.notifier) as _Chat).reviewed, 1);
      expect(c.read(taskAcceptanceProvider)['task']!.manuallyAccepted, isFalse);
    },
  );
  testWidgets('task status and advanced forms fit phone desktop and text scale', (
    tester,
  ) async {
    final c = await container();
    addTearDown(c.dispose);
    final key = GlobalKey();
    addTearDown(tester.view.reset);
    for (final width in [360.0, 390.0, 1280.0, 1440.0]) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: dark ? AppTheme.dark() : AppTheme.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(1.24)),
                  child: child!,
                ),
                home: Scaffold(
                  body: ListView(
                    children: const [
                      TaskControlPanel(conversationId: 'c'),
                      TaskAdvancedOptions(conversationId: 'c'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('核验产物并确认通过').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'output/task-core-review/ui/task-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
  });
}
