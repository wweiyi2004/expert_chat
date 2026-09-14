import 'dart:async';

import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeSettings, FakeLlmProvider;

class _ReadFailureRepository extends DriftConversationRepository {
  _ReadFailureRepository(super.db);

  bool failReads = true;
  Completer<void>? saved;
  Completer<void>? readStarted;
  Completer<void>? releaseRead;

  @override
  Future<Conversation> loadConversation(String id) async {
    if (failReads) throw StateError('simulated read failure');
    final snapshot = await super.loadConversation(id);
    readStarted?.complete();
    await releaseRead?.future;
    return snapshot;
  }

  @override
  Future<void> saveConversation(Conversation conversation) async {
    await super.saveConversation(conversation);
    final pending = saved;
    saved = null;
    pending?.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _ReadFailureRepository repo;
  late ProviderContainer container;
  late FakeLlmProvider llm;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    repo = _ReadFailureRepository(db);
    await repo.saveConversation(
      Conversation(
        id: 'archive',
        title: 'Original title',
        messages: [
          ChatMessage(id: 'user', role: MessageRole.user, content: 'History'),
          ChatMessage(
            id: 'answer',
            role: MessageRole.assistant,
            content: 'Original answer',
            parentId: 'user',
          ),
          ChatMessage(
            id: 'alternate',
            role: MessageRole.assistant,
            content: 'Alternate answer',
            parentId: 'user',
          ),
        ],
        activeChildren: {kRootKey: 'user', 'user': 'alternate'},
      ),
    );
    llm = FakeLlmProvider(const []);
    container = ProviderContainer(
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
    await container.read(chatControllerProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'failed startup read keeps history and branches during rename',
    () async {
      final state = container.read(chatControllerProvider).requireValue;
      expect(state.current!.messagesLoaded, isFalse);
      expect(state.errorConvoId, 'archive');
      expect(state.retryOperation!.kind, ChatRetryKind.loadConversation);

      final saved = repo.saved = Completer<void>();
      container
          .read(chatControllerProvider.notifier)
          .renameConversation('archive', 'Renamed');
      await saved.future;
      final stored = await DriftConversationRepository(
        db,
      ).loadConversation('archive');
      expect(stored.title, 'Renamed');
      expect(stored.messages, hasLength(3));
      expect(stored.activePath.last.content, 'Alternate answer');
    },
  );

  test(
    'unloaded history rejects text, image and background document turns',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      expect(await controller.sendMessage('Do not replace history'), isFalse);
      expect(await controller.generateImage('Do not generate'), isFalse);
      expect(
        await controller.sendLongDocumentTask(
          'Do not upload',
          attachments: [
            Attachment(
              name: 'document.txt',
              mimeType: 'text/plain',
              imageBase64: 'QQ==',
            ),
          ],
        ),
        isFalse,
      );
      expect(llm.calls, isEmpty);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .current!
            .messagesLoaded,
        isFalse,
      );
      expect((await db.select(db.messages).get()), hasLength(3));
    },
  );

  test(
    'retry reloads history without invoking a model or adding a branch',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      // A repeated failure remains retryable.
      await controller.retryLast();
      expect(
        container.read(chatControllerProvider).requireValue.error,
        isNotNull,
      );
      repo.failReads = false;
      controller.renameConversation('archive', 'Renamed before retry');
      await controller.retryLast();
      final recovered = container.read(chatControllerProvider).requireValue;
      expect(recovered.current!.title, 'Renamed before retry');
      expect(recovered.current!.messagesLoaded, isTrue);
      expect(recovered.current!.messages, hasLength(3));
      expect(recovered.current!.activePath.last.id, 'alternate');
      expect(recovered.error, isNull);
      expect(recovered.retryOperation, isNull);
      expect(llm.calls, isEmpty);
    },
  );

  test('a rename during reload survives the older read snapshot', () async {
    repo.failReads = false;
    repo.readStarted = Completer<void>();
    repo.releaseRead = Completer<void>();
    final controller = container.read(chatControllerProvider.notifier);
    final retry = controller.retryLast();
    await repo.readStarted!.future;
    final saved = repo.saved = Completer<void>();
    controller.renameConversation('archive', 'Edited while loading');
    repo.releaseRead!.complete();
    await retry;
    await saved.future;
    final recovered = container
        .read(chatControllerProvider)
        .requireValue
        .current!;
    expect(recovered.title, 'Edited while loading');
    expect(recovered.messages, hasLength(3));
    final stored = await DriftConversationRepository(
      db,
    ).loadConversation('archive');
    expect(stored.title, recovered.title);
    expect(stored.messages, hasLength(3));
  });
}
