import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/features/chat/widgets/chat_workspace_options.dart';
import 'package:expert_chat/state/conversation_workspace_bindings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'desktop_workspaces_page_test.dart' show MemoryHost;

void main() {
  testWidgets(
    'work options defaults automatically and can bind or release a project',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final host = MemoryHost();
      await host.add(
        id: 'project',
        name: '项目工作区',
        path: 'E:/project',
        access: WorkspaceAccess.readOnly,
      );
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          desktopWorkspaceHostProvider.overrideWithValue(host),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: ChatWorkspaceBar(conversationId: 'chat', busy: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('E:/App/desktop-workspaces/default'), findsOneWidget);
      expect(container.read(conversationWorkspaceBindingsProvider), isEmpty);
      await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('select-workspace-project')),
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-workspace-project')));
      await tester.pumpAndSettle();
      expect(
        container.read(conversationWorkspaceBindingsProvider)['chat'],
        'project',
      );
      expect(find.text('E:/project'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-workspace-bar')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('use-default-workspace')),
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('use-default-workspace')));
      await tester.pumpAndSettle();
      expect(container.read(conversationWorkspaceBindingsProvider), isEmpty);
      expect(find.text('E:/App/desktop-workspaces/default'), findsOneWidget);
    },
  );
}
