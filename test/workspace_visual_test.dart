import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/features/shell/app_shell.dart';
import 'package:expert_chat/features/shell/conversation_return_scope.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'widget_test.dart'
    show FakeSettings, InMemoryRepo, InMemoryLibraryFileStore;

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('RENDER_WORKSPACE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('workspace-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/workspace-$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Expert Chat',
      packageName: 'com.wweiyi.expert_chat',
      version: '3.6.1',
      buildNumber: '4109',
      buildSignature: '',
    );
    if (!const bool.fromEnvironment('RENDER_WORKSPACE')) return;
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await font.load();
    await icons.load();
  });
  testWidgets(
    'phone sidebar reaches grouped settings and preserves the draft',
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
          settingsControllerProvider.overrideWith(FakeSettings.new),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          libraryFileStoreProvider.overrideWithValue(
            InMemoryLibraryFileStore(),
          ),
        ],
      );
      await container.read(chatControllerProvider.future);
      final navigatorKey = GlobalKey<NavigatorState>();
      final routeObserver = ConversationRouteObserver();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: [routeObserver],
            theme: AppTheme.light(),
            builder: (_, child) => RepaintBoundary(
              key: const ValueKey('workspace-render'),
              child: ConversationReturnScope(
                navigatorKey: navigatorKey,
                observer: routeObserver,
                child: child!,
              ),
            ),
            home: const AppShell(),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await _capture(tester, 'chat');
      expect(
        find
            .byKey(const ValueKey('chat-new-conversation-button'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.more_horiz),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('会话操作'));
      await tester.pumpAndSettle();
      expect(find.text('导出 Markdown'), findsOneWidget);
      expect(find.text('允许联网检索'), findsOneWidget);
      expect(find.text('工具权限'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      if (const bool.fromEnvironment('RENDER_WORKSPACE')) {
        await tester.tap(find.text('深度思考'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('composer-reasoning-effort-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('reasoning-effort-dialog')),
          findsOneWidget,
        );
        await _capture(tester, 'reasoning-effort');
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byKey(const ValueKey('composer-text-field')),
        '保留的草稿',
      );
      await tester.tap(find.byType(DrawerButton).first);
      await tester.pumpAndSettle();

      expect(find.text('资料库'), findsOneWidget);
      expect(find.text('自动化'), findsOneWidget);
      await _capture(tester, 'sidebar');
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-overview')), findsOneWidget);
      await _capture(tester, 'settings');
      await tester.tap(find.text('外观与数据'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('明暗模式'),
        240,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-appearanceData')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.text('明暗模式'));
      await tester.pumpAndSettle();
      expect(find.text('明暗模式'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-overview')), findsOneWidget);
      expect(find.byTooltip('打开侧边栏'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('composer-text-field')),
            )
            .controller!
            .text,
        '保留的草稿',
      );
      tester.view.physicalSize = const Size(1280, 840);
      await tester.pumpAndSettle();
      expect(find.text('资料库').hitTestable(), findsOneWidget);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('助手与技能'), findsOneWidget);
      // The desktop destination is modal: sidebar state remains mounted below
      // its barrier and becomes reachable again after closing.
      expect(find.text('资料库').hitTestable(), findsNothing);
      await _capture(tester, 'desktop-settings');
      await tester.tap(find.byTooltip('回到对话'));
      await tester.pumpAndSettle();
      expect(find.text('资料库').hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('composer-text-field')),
            )
            .controller!
            .text,
        '保留的草稿',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
    },
  );
}
