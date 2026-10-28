import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _LiveLlm implements LlmProvider {
  final chunks = StreamController<ChatChunk>();
  final entered = Completer<void>();
  int requests = 0;
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
    requests++;
    token = cancelToken;
    entered.complete();
    return chunks.stream;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('expert_chat/generation');

  test(
    'background checkpoints the reply and resume keeps the same request',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platformCalls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        platformCalls.add(call.method);
        return null;
      });
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final repo = InMemoryRepo();
      final llm = _LiveLlm();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(repo),
          settingsControllerProvider.overrideWith(FakeSettings.new),
          llmProvider.overrideWithValue(llm),
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await Future<void>.delayed(Duration.zero);
        await llm.chunks.close();
        await db.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      await container.read(chatControllerProvider.future);
      final controller = container.read(chatControllerProvider.notifier);
      controller.applyComposerPrefs(
        searchMode: SearchMode.off,
        imageGenMode: ImageGenMode.off,
        reasoningEffort: ReasoningEffort.high,
      );
      final sent = controller.sendMessage('hello');
      await llm.entered.future;
      expect(platformCalls, ['start']);
      llm.chunks.add(const ChatChunk(contentDelta: 'before background'));
      await Future<void>.delayed(Duration.zero);
      controller.reportAppBackground(true);
      await Future<void>.delayed(Duration.zero);
      expect(repo.store.single.activePath.last.content, 'before background');
      expect(llm.token!.isCancelled, isFalse);
      expect(llm.chunks.hasListener, isTrue);
      llm.chunks.add(const ChatChunk(contentDelta: ' / while background'));
      await Future<void>.delayed(Duration.zero);
      controller.reportAppBackground(false);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .current!
            .activePath
            .last
            .content,
        'before background / while background',
      );
      expect(platformCalls, ['start']);
      expect(llm.requests, 1);
      llm.chunks.add(const ChatChunk(finishReason: 'stop'));
      await llm.chunks.close();
      expect(await sent, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(platformCalls, ['start', 'stop']);
      expect(
        container.read(chatControllerProvider).requireValue.isStreaming,
        isFalse,
      );
    },
  );
}
