import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/shell/conversation_return_scope.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [Conversation(id: 'kept', title: '原会话')],
    currentId: 'kept',
  );
}

void main() {
  testWidgets('Esc closes settings drawer before returning to original chat', (
    tester,
  ) async {
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
    final navigator = GlobalKey<NavigatorState>();
    final scaffold = GlobalKey<ScaffoldState>();
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
            key: scaffold,
            appBar: AppBar(title: const Text('设置')),
            drawer: const Drawer(child: Text('导航抽屉')),
            body: const Text('设置正文'),
          ),
        ),
      ),
    );
    await tester.pump();
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(scaffold.currentState!.isDrawerOpen, isFalse);
    expect(container.read(shellTabProvider), ShellTab.settings);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(container.read(shellTabProvider), ShellTab.chat);
    expect(
      container.read(chatControllerProvider).requireValue.currentId,
      'kept',
    );
    expect(tester.takeException(), isNull);
    container.read(shellTabProvider.notifier).set(ShellTab.settings);
    var rejected = 0;
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            // ignore: deprecated_member_use - regression for legacy willPop guards.
            WillPopScope(
              onWillPop: () async {
                rejected++;
                return false;
              },
              child: const Scaffold(body: Text('legacy guarded editor')),
            ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('回到对话'));
    await tester.pumpAndSettle();
    expect(
      rejected,
      2,
      reason: 'at most one same-route retry after the initial rejection',
    );
    expect(find.text('legacy guarded editor'), findsOneWidget);
    expect(container.read(shellTabProvider), ShellTab.settings);
    expect(tester.takeException(), isNull);
  });
}
