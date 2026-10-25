import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _KeyboardChat extends ChatController {
  int sends = 0;
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [
      Conversation(
        id: 'work',
        workMode: true,
        messages: [ChatMessage(role: MessageRole.user, content: 'task')],
      ),
    ],
  );
  @override
  Future<bool> sendMessage(
    String text, {
    List<Attachment> attachments = const [],
    bool forceDocumentEdit = false,
  }) async {
    sends++;
    return true;
  }
}

bool _focusedInside(WidgetTester tester, Finder finder) {
  final expected = tester.element(finder);
  final current = FocusManager.instance.primaryFocus?.context;
  var found = identical(expected, current);
  current?.visitAncestorElements((element) {
    if (identical(element, expected)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

Future<void> _tabTo(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  for (var i = 0; i < 24 && !_focusedInside(tester, finder); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(
    _focusedInside(tester, finder),
    isTrue,
    reason: 'Tab reaches $key through actual focus traversal',
  );
}

void main() {
  testWidgets(
    'prototype composer chips activate with Enter without sending and editor preserves keyboard rules',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        SharedPreferences.setMockInitialValues({});
        final db = AppDatabase(NativeDatabase.memory());
        final chat = _KeyboardChat();
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(
              await SharedPreferences.getInstance(),
            ),
            appDatabaseProvider.overrideWithValue(db),
            conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
            settingsControllerProvider.overrideWith(FakeSettings.new),
            desktopWorkspaceHostProvider.overrideWithValue(
              stub.createDesktopWorkspaceHost(),
            ),
            chatControllerProvider.overrideWith(() => chat),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await db.close();
        });
        tester.view.physicalSize = const Size(790, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              home: const ChatPage(desktopShell: true),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('composer-text-field'));
        await tester.enterText(field, 'nonempty draft');
        await _tabTo(tester, const ValueKey('composer-permission'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('工具权限'), findsOneWidget);
        expect(chat.sends, 0);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.enterText(field, 'nonempty draft');
        await _tabTo(tester, const ValueKey('composer-model-thinking'));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('模型与思考'), findsOneWidget);
        expect(chat.sends, 0);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.enterText(field, 'line');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(chat.sends, 0);
        // Hardware key dispatch intentionally does not emulate the platform
        // text-input client. The desktop IME supplies the newline editing delta
        // before its newline action (EditableText.performAction's contract).
        expect(
          tester.widget<TextField>(field).textInputAction,
          TextInputAction.newline,
        );
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'line\n',
            selection: TextSelection.collapsed(offset: 5),
          ),
        );
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();
        expect(chat.sends, 0);
        expect(tester.widget<TextField>(field).controller!.text, 'line\n');
        final editor = tester.widget<TextField>(field).controller!;
        editor.value = const TextEditingValue(
          text: '拼音',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(chat.sends, 0);
        editor.value = const TextEditingValue(
          text: 'send now',
          selection: TextSelection.collapsed(offset: 8),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(chat.sends, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
