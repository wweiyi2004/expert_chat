import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/work_session_footer.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/features/shell/conversation_return_scope.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart' show FakeSettings;

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [Conversation(id: 'kept', title: '原聊天')],
    currentId: 'kept',
  );
}

void main() {
  testWidgets(
    'chat usage settings and its child return in one click without affecting plain workbench routes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          chatControllerProvider.overrideWith(_Chat.new),
          settingsControllerProvider.overrideWith(FakeSettings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(chatControllerProvider.future);
      await container.read(settingsControllerProvider.future);
      final draft = TextEditingController(text: '保留原聊天草稿');
      addTearDown(draft.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final observer = ConversationRouteObserver();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer],
            builder: (context, child) => ConversationReturnScope(
              navigatorKey: navigator,
              observer: observer,
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  TextField(controller: draft),
                  const WorkSessionFooter(
                    conversationId: 'kept',
                    busy: false,
                    workMode: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/workbench/fullscreen'),
          builder: (_) => Scaffold(appBar: AppBar(title: const Text('普通工作台'))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('回到对话'), findsNothing);
      expect(observer.hasSettingsDestination, isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('work-context-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('用量与单价 · 前往设置 › 模型'));
      await tester.pumpAndSettle();
      expect(container.read(shellTabProvider), ShellTab.chat);
      expect(observer.hasSettingsDestination, isTrue);
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('回到对话'), findsOneWidget);
      final settingsScroll = find
          .descendant(
            of: find.byKey(const ValueKey('settings-model')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('首次模型设置向导'),
        250,
        scrollable: settingsScroll,
      );
      await tester.ensureVisible(find.text('首次模型设置向导'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('首次模型设置向导'));
      await tester.pumpAndSettle();
      expect(find.text('连接你的模型'), findsOneWidget);
      expect(observer.hasSettingsDestination, isTrue);
      expect(find.text('回到对话'), findsOneWidget);
      await tester.tap(find.text('回到对话'));
      await tester.pumpAndSettle();
      expect(observer.rootVisible, isTrue);
      expect(observer.hasSettingsDestination, isFalse);
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.text('回到对话'), findsNothing);
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'kept',
      );
      expect(draft.text, '保留原聊天草稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
