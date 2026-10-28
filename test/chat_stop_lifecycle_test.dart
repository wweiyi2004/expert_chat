import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/character_repository.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/world_info_repository.dart';
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import 'widget_test.dart' show FakeSettings, InMemoryLibraryFileStore, InMemoryRepo;

/// Streams one chunk, then waits on [gate] before finishing. Lets a test stop
/// the turn while the model is still mid-answer.
class _GatedLlm implements LlmProvider {
  _GatedLlm(this.gate);

  final Completer<void> gate;
  final entered = Completer<void>();
  int calls = 0;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls++;
    if (!entered.isCompleted) entered.complete();
    yield const ChatChunk(contentDelta: '部分回答');
    await gate.future;
    yield const ChatChunk(contentDelta: '之后的内容', finishReason: 'stop');
  }
}

ProviderContainer _container(LlmProvider llm, SharedPreferences prefs) {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      llmProvider.overrideWithValue(llm),
      conversationRepositoryProvider.overrideWithValue(InMemoryRepo()),
      settingsControllerProvider.overrideWith(FakeSettings.new),
      appDatabaseProvider.overrideWithValue(db),
      libraryFileStoreProvider.overrideWithValue(InMemoryLibraryFileStore()),
      characterRepositoryProvider.overrideWithValue(CharacterRepository(db)),
      worldInfoRepositoryProvider.overrideWithValue(WorldInfoRepository(db)),
      // No desktop execution end in the test host; these cases need no files.
      desktopWorkspaceHostProvider.overrideWithValue(
        stub.createDesktopWorkspaceHost(),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stopping mid-answer ends the turn without an error banner', () async {
    final gate = Completer<void>();
    final llm = _GatedLlm(gate);
    final prefs = await SharedPreferences.getInstance();
    final container = _container(llm, prefs);
    await container.read(chatControllerProvider.future);
    final ctrl = container.read(chatControllerProvider.notifier);
    ctrl.newConversation();

    final sent = ctrl.sendMessage('请回答');
    await llm.entered.future.timeout(const Duration(seconds: 10));
    ctrl.stop();
    gate.complete();
    await sent.timeout(const Duration(seconds: 10));

    final state = container.read(chatControllerProvider).requireValue;
    expect(state.isStreaming, isFalse);
    expect(state.error, isNull);
    final reply = state.current!.activePath.last;
    expect(reply.role, MessageRole.assistant);
    expect(reply.content, contains('部分回答'));
    expect(reply.content, isNot(contains('之后的内容')));
  });

  test('a new message after a stop completes normally', () async {
    final gate = Completer<void>();
    final llm = _GatedLlm(gate);
    final prefs = await SharedPreferences.getInstance();
    final container = _container(llm, prefs);
    await container.read(chatControllerProvider.future);
    final ctrl = container.read(chatControllerProvider.notifier);
    ctrl.newConversation();

    final first = ctrl.sendMessage('第一条');
    await llm.entered.future.timeout(const Duration(seconds: 10));
    ctrl.stop();
    gate.complete();
    await first.timeout(const Duration(seconds: 10));

    // The second turn must not be blocked by the stopped one.
    final second = await ctrl.sendMessage('第二条').timeout(
      const Duration(seconds: 10),
    );
    expect(second, isTrue);
    final state = container.read(chatControllerProvider).requireValue;
    expect(state.isStreaming, isFalse);
    expect(state.error, isNull);
    expect(state.current!.activePath.last.content, contains('之后的内容'));
  });

  test(
    'work mode: stopping marks the task cancelled and late output cannot revive it',
    () async {
      final gate = Completer<void>();
      final llm = _GatedLlm(gate);
      final prefs = await SharedPreferences.getInstance();
      final container = _container(llm, prefs);
      await container.read(chatControllerProvider.future);
      final ctrl = container.read(chatControllerProvider.notifier);
      ctrl.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;

      final sent = ctrl.sendMessage('请执行任务');
      await llm.entered.future.timeout(const Duration(seconds: 10));
      ctrl.stop(conversationId: id);
      gate.complete();
      await sent.timeout(const Duration(seconds: 10));

      final state = container.read(chatControllerProvider).requireValue;
      expect(state.error, isNull);
      expect(state.isStreaming, isFalse);
      final checkpoint = state.sessionCheckpoints[id];
      expect(checkpoint, isNotNull, reason: '工作模式应留下执行检查点');
      expect(checkpoint!.status, SessionExecutionStatus.cancelled);

      // Give any late event a chance to run; the stopped task must stay stopped.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final later = container.read(chatControllerProvider).requireValue;
      expect(
        later.sessionCheckpoints[id]?.status,
        SessionExecutionStatus.cancelled,
      );
    },
  );

  test(
    'cancelling one live work session leaves the other session running',
    () async {
      final gate = Completer<void>();
      final llm = _GatedLlm(gate);
      final prefs = await SharedPreferences.getInstance();
      final container = _container(llm, prefs);
      await container.read(chatControllerProvider.future);
      final ctrl = container.read(chatControllerProvider.notifier);

      ctrl.newConversation(workMode: true, forceNew: true);
      final a = container.read(chatControllerProvider).requireValue.currentId!;
      final sentA = ctrl.sendMessage('任务 A');
      await llm.entered.future.timeout(const Duration(seconds: 10));

      ctrl.newConversation(workMode: true, forceNew: true);
      final b = container.read(chatControllerProvider).requireValue.currentId!;
      final sentB = ctrl.sendMessage('任务 B');

      ctrl.stop(conversationId: a);
      gate.complete();
      await sentA.timeout(const Duration(seconds: 10));
      await sentB.timeout(const Duration(seconds: 10));

      final state = container.read(chatControllerProvider).requireValue;
      expect(state.sessionCheckpoints[a]?.status,
          SessionExecutionStatus.cancelled);
      expect(state.sessionCheckpoints[b]?.status,
          SessionExecutionStatus.completed);
      final bReply = state.conversations
          .firstWhere((c) => c.id == b)
          .activePath
          .last;
      expect(bReply.content, contains('之后的内容'));
    },
  );
}
