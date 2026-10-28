import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/host_client_bootstrap.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/platform/theme_mode.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/domain/host/wire_models.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/task_plans.dart';
import 'package:expert_chat/features/chat/widgets/task_plan_card.dart';
import 'package:expert_chat/features/chat/widgets/task_overview_dialog.dart';
import 'package:expert_chat/features/chat/widgets/checkpoint_dialog.dart';

void main() {
  if (!const bool.fromEnvironment('HOST_GUI_INTEGRATION_TEST')) return;
  testWidgets(
    'real host GUI projections reject stale plan approval and expose shared task/checkpoint views',
    (tester) async {
      final directory = Platform.environment['EXPERT_HOST_DATA_DIR'] ?? '';
      expect(
        directory,
        contains('ui-profile-'),
      ); // Never attach a production profile.
      final bootstrap = (await tester.runAsync(HostClientBootstrap.open))!;
      debugPrint('GUI fixture: host attached');
      await tester.runAsync(() async {
        await (FontLoader(
          'NotoSansSC',
        )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      debugPrint('GUI fixture: fonts loaded');
      final plans = wireMap(
        wireMap(bootstrap.client.state['runtime'])['plans'],
      );
      final id = plans.keys.first;
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('host-ui-evidence'),
          child: bootstrap.wrap(
            MaterialApp(
              theme: AppTheme.light(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      TaskPlanCard(conversationId: id),
                      TextButton(
                        onPressed: () => showTaskOverview(context),
                        child: const Text('打开任务总览'),
                      ),
                      TextButton(
                        onPressed: () => showCheckpointDialog(context, id),
                        child: const Text('打开检查点'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      debugPrint('GUI fixture: first widget pump');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TaskPlanCard)),
        listen: false,
      );
      Future<void> settle(bool Function() ready) async {
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          if (ready()) return;
        }
        fail('Host projection did not settle');
      }

      await settle(() => container.read(chatControllerProvider).value != null);
      debugPrint('GUI fixture: chat ready');
      await tester.runAsync(() async {
        await container.read(settingsControllerProvider.future);
        debugPrint('GUI fixture: settings ready');
        await container
            .read(settingsControllerProvider.notifier)
            .apply(themeMode: ThemePreference.dark);
      });
      expect(
        container.read(settingsControllerProvider).requireValue.themeMode,
        ThemePreference.dark,
      );
      debugPrint('GUI fixture: settings saved');
      Future<void> capture(String name) async {
        debugPrint('GUI fixture: capture $name');
        await tester.pump(const Duration(milliseconds: 500));
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('host-ui-evidence')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory('output/shared-host-validation/gui-images');
          await output.create(recursive: true);
          await File(
            '${output.path}/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      try {
        await tester.tap(find.text('查看计划'));
        await tester.pumpAndSettle();
        expect(find.text('批准此版本并继续'), findsOneWidget);
        await capture('plan-wide');
        tester.view.physicalSize = const Size(360, 640);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await capture('plan-narrow');
        tester.view.physicalSize = const Size(1000, 800);
        await tester.pumpAndSettle();
        final old = container.read(taskPlansProvider)[id]!;
        await tester.runAsync(() async {
          await bootstrap.client.invoke('plan.comment', {
            'session_id': id,
            'revision': old.revision,
            'text': '来自另一客户端的合成修改意见',
          });
          await bootstrap.client.refresh(force: true);
        });
        await settle(() => find.text('计划已变化，请关闭后重新查看。').evaluate().isNotEmpty);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, '批准此版本并继续'),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查看计划'));
        await tester.pumpAndSettle();
        expect(find.textContaining('来自另一客户端的合成修改意见'), findsWidgets);
        await tester.tap(find.widgetWithText(FilledButton, '批准此版本并继续'));
        await settle(() => find.byType(AlertDialog).evaluate().isEmpty);
        await settle(
          () => container.read(taskPlansProvider)[id]?.approved == true,
        );
        await tester.tap(find.text('打开任务总览'));
        await tester.pumpAndSettle();
        expect(find.text('任务总览'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture('tasks-wide');
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开检查点'));
        await settle(
          () => find.byType(DropdownButton<String>).evaluate().isNotEmpty,
        );
        await tester.tap(find.text('查看回退范围'));
        await settle(() => find.textContaining('仅回退有记录').evaluate().isNotEmpty);
        for (final label in ['新分支', '仅回退会话', '仅回退文件', '回退会话与文件']) {
          expect(find.text(label), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await capture('checkpoints-wide');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await bootstrap.database.close();
          await bootstrap.client.close();
        });
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
