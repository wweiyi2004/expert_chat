import 'package:expert_chat/core/gui_providers.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/chat_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

import 'widget_test.dart'
    show
        FakeLlmProvider,
        FakeSettings,
        FakeSpeechInputService,
        FakeTextToSpeechService,
        InMemoryLibraryFileStore,
        InMemoryRepo;

void main() {
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('voice mode sends a spoken turn, reads the reply and listens '
      'again', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final mic = FakeSpeechInputService();
    final speaker = FakeTextToSpeechService();
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        sharedPrefsProvider.overrideWithValue(prefs),
        conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
        libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
        settingsControllerProvider.overrideWith(FakeSettings.new),
        llmProvider.overrideWithValue(
          FakeLlmProvider(const [
            ChatChunk(contentDelta: '今天晴。'),
            ChatChunk(contentDelta: '气温二十度。'),
          ]),
        ),
        speechInputServiceProvider.overrideWithValue(mic),
        textToSpeechServiceProvider.overrideWithValue(speaker),
      ],
    );
    addTearDown(c.dispose);
    await c.read(chatControllerProvider.future);
    await c.read(settingsControllerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: ChatPage()),
      ),
    );
    await drain(tester);

    await tester.tap(find.byKey(const ValueKey('composer-plus-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音对话'));
    await drain(tester);
    expect(
      find.byKey(const ValueKey('voice-conversation-panel')),
      findsOneWidget,
    );
    expect(find.textContaining('正在听'), findsOneWidget);

    mic
      ..emit('今天天气怎么样')
      ..endSession();
    await drain(tester);

    final convo = c.read(chatControllerProvider).value!.current!;
    expect(convo.activePath.first.content, '今天天气怎么样');
    expect(convo.activePath.last.content, '今天晴。气温二十度。');
    final spoken = speaker.streams.single;
    expect(spoken.isClosed, isTrue);
    expect(
      [for (var i = 0; i < spoken.length; i++) spoken[i]],
      ['今天晴。', '气温二十度。'],
    );

    speaker.finishStream();
    await drain(tester);
    expect(mic.startCount, 2);
    expect(find.textContaining('正在听'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('voice-conversation-exit')));
    await drain(tester);
    expect(
      find.byKey(const ValueKey('voice-conversation-panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('composer-microphone-button')),
      findsOneWidget,
    );
  });
}
