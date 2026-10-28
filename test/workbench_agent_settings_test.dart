import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/features/workbench/workspace_workbench_page.dart';
import 'package:expert_chat/features/settings/settings_page.dart';
import 'package:expert_chat/features/settings/widgets/agent_instructions_editor.dart';
import 'package:expert_chat/features/shell/conversation_return_scope.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    workAgentInstructions: 'keep current work instructions',
  );
}

class _Chat extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [
      Conversation(id: 'work', title: 'original work', workMode: true),
    ],
  );
}

void main() {
  testWidgets(
    'workbench links to the unique assistant settings editor and preserves saving and return',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          desktopWorkspaceHostProvider.overrideWithValue(
            stub.createDesktopWorkspaceHost(),
          ),
          settingsControllerProvider.overrideWith(_Settings.new),
          chatControllerProvider.overrideWith(_Chat.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });
      await container.read(settingsControllerProvider.future);
      await container.read(chatControllerProvider.future);
      final key = GlobalKey<NavigatorState>();
      final observer = ConversationRouteObserver();
      addTearDown(observer.dispose);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: key,
            navigatorObservers: [observer],
            theme: AppTheme.light(),
            builder: (context, child) => ConversationReturnScope(
              navigatorKey: key,
              observer: observer,
              child: child!,
            ),
            home: const Scaffold(
              body: WorkspaceWorkbenchPage(
                conversationId: 'work',
                embedded: true,
                initialTab: 10,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final workbench = find.byType(WorkspaceWorkbenchPage);
      expect(
        find.descendant(of: workbench, matching: find.byType(TextField)),
        findsNothing,
      );
      expect(find.byType(AgentInstructionsEditor), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('workbench-edit-main-instructions')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      expect(
        tester.widget<SettingsPage>(find.byType(SettingsPage)).initialCategory,
        SettingsCategory.assistants,
      );
      expect(observer.hasSettingsDestination, isTrue);
      expect(observer.pageDepth, 2);
      final editor = find.byKey(const ValueKey('work-agent-instructions'));
      await tester.ensureVisible(editor);
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(find.byType(AgentInstructionsEditor), findsOneWidget);
      final field = find.descendant(
        of: editor,
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'keep current work instructions',
      );
      await tester.enterText(field, 'updated once in assistant settings');
      await tester.pump();
      final save = find.descendant(of: editor, matching: find.text('保存'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .workAgentInstructions,
        'updated once in assistant settings',
      );
      expect(
        prefs.getString('workAgentInstructions'),
        'updated once in assistant settings',
      );
      final back = find.byTooltip('回到对话');
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(observer.pageDepth, 1);
      expect(
        container.read(chatControllerProvider).requireValue.currentId,
        'work',
      );
      expect(
        find
            .byKey(const ValueKey('workbench-edit-main-instructions'))
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.descendant(of: workbench, matching: find.byType(TextField)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
