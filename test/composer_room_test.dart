import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_changes.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/work_rounds.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'desktop_workspaces_page_test.dart' show MemoryHost;
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [
      Conversation(id: 'work', title: 'new work', workMode: true),
    ],
  );
}

class _Changes extends WorkChanges {
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return const [];
  }
}

class _Approvals extends WorkApprovals {
  @override
  List<PendingWorkApproval> build() => [
    PendingWorkApproval(
      id: 'a',
      conversationId: 'work',
      tool: 'workspace_shell',
      target: '默认工作区',
      reason: '运行项目验证命令',
      arguments: '{"command":"flutter test"}',
    ),
  ];
}

class _Rounds extends WorkRounds {
  @override
  Map<String, WorkRoundProgress> build() => {
    'work': const WorkRoundProgress(
      runId: 'r',
      limit: 12,
      step: 5,
      reviewAhead: 1,
      autoExtend: false,
      used: 4,
      paused: true,
      pauseRequested: true,
    ),
  };
}

Future<void> _capture(WidgetTester tester, String tag) async {
  final composer = tester.getRect(find.byKey(const ValueKey('chat-composer')));
  final box = tester.getRect(find.byKey(const ValueKey('composer-input-box')));
  final editor = tester.getRect(
    find.byKey(const ValueKey('composer-text-field')),
  );
  final info = <String, Object?>{
    'input': {
      'x': box.left,
      'y': box.top,
      'width': box.width,
      'height': box.height,
    },
    'editor': {
      'x': editor.left,
      'y': editor.top,
      'width': editor.width,
      'height': editor.height,
    },
    'outsideContext': find
        .byKey(const ValueKey('composer-context-row'))
        .evaluate()
        .length,
  };
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('room-render')),
  );
  await tester.runAsync(() async {
    final full = await boundary.toImage(pixelRatio: 1);
    final crop = composer.intersect(
      Offset.zero & Size(full.width.toDouble(), full.height.toDouble()),
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(
      recorder,
    ).drawImageRect(full, crop, Offset.zero & crop.size, ui.Paint());
    final picture = recorder.endRecording();
    final image = await picture.toImage(crop.width.ceil(), crop.height.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/ui-feedback-review/screenshots/input-$tag.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    full.dispose();
    await File(
      'output/ui-feedback-review/screenshots/input-$tag.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(info));
  });
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final scenario in [
    (990.0, false, false, 'narrow-pane'),
    (360.0, false, false, 'phone-360'),
    (390.0, false, false, 'phone-390'),
    (360.0, true, true, 'phone-keyboard-usage'),
    (1600.0, false, false, 'wide-pane'),
  ]) {
    testWidgets('input room ${scenario.$4}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          chatControllerProvider.overrideWith(_Chat.new),
          workChangesProvider.overrideWith(_Changes.new),
          if (scenario.$2) ...[
            workApprovalsProvider.overrideWith(_Approvals.new),
            workRoundsProvider.overrideWith(_Rounds.new),
          ],
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      tester.view.physicalSize = Size(scenario.$1, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (scenario.$3) {
        container
            .read(workSessionInsightsProvider.notifier)
            .request(
              'work',
              'r',
              'test-model',
              [
                const LlmRequestMessage(
                  role: MessageRole.user,
                  content: 'real usage snapshot',
                ),
              ],
              [],
              contextBudgetTokens: 1000,
            );
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: RepaintBoundary(
                key: const ValueKey('room-render'),
                child: child!,
              ),
            ),
            home: const ChatPage(desktopShell: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scenario.$2) {
        await tester.enterText(
          find.byKey(const ValueKey('composer-text-field')),
          '补充验收',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
      }
      final box = find.byKey(const ValueKey('composer-input-box'));
      final field = find.byKey(const ValueKey('composer-text-field'));
      if (scenario.$1 < 1600) {
        final outside = find.byKey(const ValueKey('composer-context-row'));
        expect(outside, findsOneWidget);
        expect(
          tester.getBottomLeft(outside).dy,
          lessThanOrEqualTo(tester.getTopLeft(box).dy),
        );
        expect(
          find.descendant(
            of: box,
            matching: find.byKey(const ValueKey('chat-workspace-bar')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: box,
            matching: find.byKey(const ValueKey('composer-permission')),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: outside,
            matching: find.byKey(const ValueKey('chat-workspace-bar')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: outside,
            matching: find.byKey(const ValueKey('composer-permission')),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('composer-input-actions')),
          findsOneWidget,
        );
        if (!scenario.$2) {
          expect(tester.widget<TextField>(field).minLines, 2);
          expect(tester.getSize(field).height, greaterThanOrEqualTo(42));
        }
        final model = tester.getRect(
          find.byKey(const ValueKey('composer-model-thinking')),
        );
        expect(model.center.dx, lessThan(tester.getRect(box).center.dx + 35));
      } else {
        expect(
          find.byKey(const ValueKey('composer-context-row')),
          findsNothing,
        );
        expect(tester.getSize(box).width, 700);
      }
      if (scenario.$3) {
        expect(
          find.descendant(
            of: box,
            matching: find.byKey(const ValueKey('work-context-details')),
          ),
          findsOneWidget,
        );
      } else {
        expect(
          find.descendant(
            of: box,
            matching: find.byKey(const ValueKey('work-context-details')),
          ),
          findsNothing,
        );
      }
      final bottom = scenario.$2 ? 600.0 : 900.0;
      expect(tester.getBottomLeft(box).dy, lessThanOrEqualTo(bottom));
      expect(field.hitTestable(), findsOneWidget);
      expect(
        find.byTooltip(scenario.$2 ? '发送' : '语音输入').hitTestable(),
        findsOneWidget,
      );
      if (scenario.$2) {
        expect(find.text('批准这一次').hitTestable(), findsOneWidget);
        expect(find.text('拒绝').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await _capture(tester, scenario.$4);
      if (scenario.$4 == 'narrow-pane') {
        await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
        await tester.pumpAndSettle();
        expect(find.text('上下文与用量'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('work-context-details')).hitTestable(),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('work-context-details')));
        await tester.pumpAndSettle();
        expect(find.text('上下文与用量'), findsNWidgets(2));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
