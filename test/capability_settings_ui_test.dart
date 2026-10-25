import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/features/settings/widgets/text_value_dialog.dart';
import 'package:expert_chat/features/settings/widgets/supervisor_settings_panel.dart';
import 'package:expert_chat/features/settings/widgets/role_validation_panel.dart';
import 'widget_test.dart' show FakeSettings;

void main() {
  testWidgets(
    '320px large-font text dialogs save and close through reverse transition safely',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      String? value;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  value = await showDialog<String>(
                    context: context,
                    builder: (_) => TextValueDialog(
                      title: '角色验收指令',
                      initialText: 'Long prompt\n' * 30,
                      label: '指令',
                      minLines: 3,
                      maxLines: 8,
                      description: 'Actual trial result evidence\n' * 12,
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(value, contains('Long prompt'));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'supervisor and role validation controls fit narrow large-font viewport',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.resetPhysicalSize());
      addTearDown(() => tester.view.resetDevicePixelRatio());
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            settingsControllerProvider.overrideWith(FakeSettings.new),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [SupervisorSettingsPanel(), RoleValidationPanel()],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('可选监督模型'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('角色证据自动验收（可选）'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('角色证据自动验收（可选）'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
