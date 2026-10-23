import 'dart:io';
import 'dart:convert';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/features/shell/app_shell.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:drift/native.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/data/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings;
import 'desktop_workspaces_page_test.dart' show MemoryHost;

class LiveWork extends ChatController {
  static final answer = Platform.environment['EXPERT_RENDER_REPRO_PATH'] == null
      ? '已检查目录。\n\n- `main.dart`：入口\n\n| 文件 | 状态 |\n| --- | --- |\n| `src/main.dart` | 已读取 |\n\n完成。'
      : jsonDecode(
              File(
                Platform.environment['EXPERT_RENDER_REPRO_PATH']!,
              ).readAsStringSync(),
            )
            as String;
  @override
  Future<ChatState> build() async => ChatState(
    currentId: 'work',
    conversations: [Conversation(id: 'work', workMode: true)],
  );
  void advance(int count, {bool running = true, bool empty = false}) {
    final messages = empty
        ? <ChatMessage>[]
        : [
            ChatMessage(id: 'user', role: MessageRole.user, content: '检查项目'),
            ChatMessage(
              id: 'assistant',
              parentId: 'user',
              role: MessageRole.assistant,
              reasoning: '我会检查项目文件。' * count,
              content: count > 5
                  ? answer.substring(
                      0,
                      ((count - 5) * answer.length ~/ 13).clamp(
                        0,
                        answer.length,
                      ),
                    )
                  : '',
              searchActivities: [
                for (var i = 0; i < count; i++)
                  SearchActivity(
                    id: 'tool-$i',
                    kind: SearchActivityKind.mcp,
                    query: '读取',
                    toolName: 'coding_read_file',
                    toolArguments: '{"path":"file-$i.dart"}',
                    status: SearchActivityStatus.done,
                    resultText: '文件内容',
                    roundElapsedMillis: running ? null : 5000,
                  ),
              ],
            ),
          ];
    state = AsyncData(
      ChatState(
        currentId: 'work',
        streamingConvoId: running && !empty ? 'work' : null,
        conversations: [
          Conversation(id: 'work', workMode: true, messages: messages),
        ],
      ),
    );
  }
}

class LayoutSettings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    studyModeEnabled: false,
    creationModeEnabled: false,
  );
}

void main() {
  testWidgets(
    'hovered composer tooltip survives welcome transition and a long live work timeline',
    (tester) async {
      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          sharedPrefsProvider.overrideWithValue(prefs),
          settingsControllerProvider.overrideWith(LayoutSettings.new),
          desktopWorkspaceHostProvider.overrideWithValue(MemoryHost()),
          chatControllerProvider.overrideWith(LiveWork.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pumpAndSettle();
      final controller =
          container.read(chatControllerProvider.notifier) as LiveWork;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      addTearDown(mouse.removePointer);
      for (var turn = 0; turn < 3; turn++) {
        await tester.enterText(
          find.byKey(const ValueKey('composer-text-field')),
          '保留输入',
        );
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('composer-plus-button'))),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('添加'), findsOneWidget);
        for (var step = 0; step < 18; step++) {
          controller.advance(step);
          await tester.pump(const Duration(milliseconds: 30));
          expect(tester.takeException(), isNull);
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const ValueKey('composer-text-field')),
                )
                .controller!
                .text,
            '保留输入',
          );
          if (step == 6 || step == 12) {
            tester.view.physicalSize = Size(step == 6 ? 760 : 1300, 900);
            await tester.pump(const Duration(milliseconds: 30));
            expect(tester.takeException(), isNull);
          }
        }
        controller.advance(18, running: false);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final toggle = find.byKey(const ValueKey('work-round-toggle'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        controller.advance(0, empty: true);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
