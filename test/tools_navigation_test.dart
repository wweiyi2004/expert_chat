import 'package:expert_chat/core/prototype_widgets.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/features/shell/app_shell.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart'
    show FakeSettings, InMemoryRepo, InMemoryLibraryFileStore;

class _OptionalSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    studyModeEnabled: false,
    creationModeEnabled: false,
    researchModeEnabled: false,
  );
}

void main() {
  testWidgets('来源页面移除后，延迟导航仍能完成', (tester) async {
    final container = ProviderContainer();
    final shown = ValueNotifier(true);
    addTearDown(container.dispose);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, value, _) => value
                ? Consumer(
                    builder: (context, ref, _) => TextButton(
                      onPressed: () {
                        openShellTab(ref, ShellTab.tools);
                        shown.value = false;
                      },
                      child: const Text('移除页面并跳转'),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('移除页面并跳转'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(container.read(shellTabProvider), ShellTab.tools);
  });

  test('optional destinations share one primary navigation item', () {
    expect(ShellTab.navigation, [
      ShellTab.chat,
      ShellTab.automation,
      ShellTab.resources,
      ShellTab.settings,
    ]);
    for (final tab in [ShellTab.study, ShellTab.studio, ShellTab.terminal]) {
      expect(
        tab.navigationTab,
        tab == ShellTab.terminal ? ShellTab.settings : ShellTab.resources,
      );
    }
  });

  testWidgets('手机工具入口保留开关、返回路径和聊天草稿', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(prefs),
        settingsControllerProvider.overrideWith(_OptionalSettings.new),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
      ],
    );
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    try {
      await container.read(chatControllerProvider.future);
      final draftConversationId = container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await settle();
      await tester.pump(const Duration(seconds: 1));
      await settle();
      await tester.enterText(
        find.byKey(const ValueKey('composer-text-field')),
        '保留这份草稿',
      );
      final nav = find.byType(NavigationBar);
      expect(nav, findsNothing);
      tester.view.viewInsets = FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(nav, findsNothing);
      final editorRect = tester.getRect(
        find.byKey(const ValueKey('composer-text-field')),
      );
      final sendRect = tester.getRect(find.byTooltip('发送'));
      expect(editorRect.width, greaterThan(240));
      expect(sendRect.center.dx, greaterThan(editorRect.center.dx));
      expect(
        sendRect.right,
        lessThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('composer-input-box')))
              .right,
        ),
      );
      expect(sendRect.bottom, lessThanOrEqualTo(480));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(nav, findsNothing);

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await settle();
      await tester.tap(find.text('外观与数据'));
      await settle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(
                const ValueKey('composer-text-field'),
                skipOffstage: false,
              ),
            )
            .focusNode!
            .hasFocus,
        isFalse,
      );
      expect(find.text('进入学习中心'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('feature-module-学习模式')),
        300,
        maxScrolls: 100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-appearanceData')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await settle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('feature-module-学习模式')),
          matching: find.byType(PrototypeSwitch),
        ),
      );
      await settle();
      expect(prefs.getBool('studyModeEnabled'), isTrue);
      await tester.tap(find.text('进入学习中心'));
      await settle();
      expect(find.text('学习空间'), findsOneWidget);
      expect(container.read(shellTabProvider), ShellTab.study);
      await tester.tap(find.byTooltip('返回工具'));
      await settle();
      expect(container.read(shellTabProvider), ShellTab.resources);
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await settle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('feature-module-创作模式')),
        300,
        maxScrolls: 100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-appearanceData')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await settle();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('feature-module-创作模式')),
          matching: find.byType(PrototypeSwitch),
        ),
      );
      await settle();
      await tester.ensureVisible(find.text('进入创作中心'));
      await tester.tap(find.text('进入创作中心'));
      await settle();
      expect(container.read(shellTabProvider), ShellTab.studio);
      await tester.binding.handlePopRoute();
      await settle();
      expect(container.read(shellTabProvider), ShellTab.resources);
      await tester.tap(find.byTooltip('打开侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('conversation-row-$draftConversationId')),
      );
      await settle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('composer-text-field')),
            )
            .controller!
            .text,
        '保留这份草稿',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
    }
  });
}
