import 'dart:async';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/prompt_presets.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Settings extends FakeSettings {
  @override
  Future<SettingsState> build() async => (await super.build()).copyWith(
    promptPresets: const PromptPresets(
      activeId: 'a',
      items: [
        PromptPreset(id: 'a', name: 'A', prompt: 'PRESET_A'),
        PromptPreset(id: 'b', name: 'B', prompt: 'PRESET_B'),
      ],
    ),
  );
}

class _Llm implements LlmProvider {
  final requests = <List<LlmRequestMessage>>[];
  final first = StreamController<ChatChunk>();
  final entered = Completer<void>();
  CancelToken? token;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    requests.add(List.of(messages));
    token = cancelToken;
    if (requests.length == 1) {
      entered.complete();
      return first.stream;
    }
    return Stream.fromIterable([
      const ChatChunk(contentDelta: 'second', finishReason: 'stop'),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'switching preset and navigating away never replaces the active stream context',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      final llm = _Llm();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          sharedPrefsProvider.overrideWithValue(prefs),
          conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
          settingsControllerProvider.overrideWith(_Settings.new),
          llmProvider.overrideWithValue(llm),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await llm.first.close();
        await db.close();
      });
      await container.read(chatControllerProvider.future);
      final chat = container.read(chatControllerProvider.notifier);
      chat.applyComposerPrefs(
        searchMode: SearchMode.off,
        imageGenMode: ImageGenMode.off,
        reasoningEffort: ReasoningEffort.high,
      );
      final sent = chat.sendMessage('first');
      await llm.entered.future;
      expect(llm.requests.single.any((m) => m.content == 'PRESET_A'), true);
      chat.reportChatVisible(false);
      await container
          .read(settingsControllerProvider.notifier)
          .selectPromptPreset('b');
      llm.first.add(const ChatChunk(contentDelta: 'background tokens'));
      await Future<void>.delayed(Duration.zero);
      chat.reportChatVisible(true);
      expect(llm.token!.isCancelled, false);
      expect(llm.requests.length, 1);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last
            .content,
        'background tokens',
      );
      llm.first.add(const ChatChunk(finishReason: 'stop'));
      await llm.first.close();
      expect(await sent, true);
      expect(await chat.sendMessage('second'), true);
      expect(llm.requests.length, 2);
      expect(llm.requests.last.any((m) => m.content == 'PRESET_B'), true);
      expect(llm.requests.last.any((m) => m.content == 'PRESET_A'), false);
      expect(
        PromptPresets.decode(
          prefs.getString(PromptPresets.storageKey),
        ).activeId,
        'b',
      );
    },
  );
}
