import 'package:drift/native.dart';
import 'package:expert_chat/data/conversation_repository.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/legacy_conversation_migration.dart';
import 'package:expert_chat/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('legacy JSON migration', () {
    test(
      'restores linear parent links and active children before clearing',
      () async {
        final timestamp = DateTime.utc(2026, 1, 1);
        final messages = [
          ChatMessage(
            id: 'user-1',
            role: MessageRole.user,
            content: 'First question',
            createdAt: timestamp,
          ),
          ChatMessage(
            id: 'assistant-1',
            role: MessageRole.assistant,
            content: 'First answer',
            createdAt: timestamp.add(const Duration(seconds: 1)),
          ),
          ChatMessage(
            id: 'user-2',
            role: MessageRole.user,
            content: 'Follow-up',
            createdAt: timestamp.add(const Duration(seconds: 2)),
          ),
        ];
        final events = <String>[];
        final json = _MemoryRepository(
          name: 'json',
          conversations: [
            Conversation(
              id: 'legacy',
              messages: messages,
              updatedAt: timestamp,
            ),
          ],
          events: events,
        );
        final database = AppDatabase(NativeDatabase.memory());
        addTearDown(database.close);
        final driftRepository = DriftConversationRepository(database);
        final drift = _RecordingRepository(
          name: 'drift',
          delegate: driftRepository,
          events: events,
        );

        await migrateLegacyJsonToDrift(drift, json: json);

        expect(events, [
          'json.loadAll',
          'drift.loadAll',
          'drift.saveAll',
          'json.saveAll',
        ]);
        expect(json.conversations, isEmpty);
        final migrated = (await driftRepository.loadAll()).single;
        expect(migrated.messages.map((message) => message.parentId), [
          null,
          'user-1',
          'assistant-1',
        ]);
        expect(migrated.activeChildren, {
          kRootKey: 'user-1',
          'user-1': 'assistant-1',
          'assistant-1': 'user-2',
        });
        expect(migrated.activePath.map((message) => message.id), [
          'user-1',
          'assistant-1',
          'user-2',
        ]);
      },
    );

    test('keeps the JSON source when the drift save fails', () async {
      final legacy = Conversation(
        id: 'legacy',
        messages: [
          ChatMessage(
            id: 'message',
            role: MessageRole.user,
            content: 'Keep me',
          ),
        ],
      );
      final events = <String>[];
      final json = _MemoryRepository(
        name: 'json',
        conversations: [legacy],
        events: events,
      );
      final drift = _MemoryRepository(
        name: 'drift',
        events: events,
        failSaveAll: true,
      );

      await migrateLegacyJsonToDrift(drift, json: json);

      expect(events, ['json.loadAll', 'drift.loadAll', 'drift.saveAll']);
      expect(json.conversations, hasLength(1));
      expect(json.conversations.single, same(legacy));
    });

    test('skips when the JSON store is empty', () async {
      final events = <String>[];
      final json = _MemoryRepository(name: 'json', events: events);
      final drift = _MemoryRepository(name: 'drift', events: events);

      await migrateLegacyJsonToDrift(drift, json: json);

      expect(events, ['json.loadAll']);
    });

    test(
      'still migrates when drift already has data but JSON was not cleared',
      () async {
        final legacy = Conversation(
          id: 'legacy',
          messages: [
            ChatMessage(
              id: 'message',
              role: MessageRole.user,
              content: 'Import me',
            ),
          ],
        );
        final json = _MemoryRepository(name: 'json', conversations: [legacy]);
        final drift = _MemoryRepository(
          name: 'drift',
          conversations: [Conversation(id: 'already-imported')],
        );

        await migrateLegacyJsonToDrift(drift, json: json);

        expect(json.conversations, isEmpty);
        expect(
          drift.conversations.map((c) => c.id).toSet(),
          {'already-imported', 'legacy'},
        );
      },
    );

    test(
      'preserves conversations that already contain tree metadata',
      () async {
        final root = ChatMessage(
          id: 'root',
          role: MessageRole.user,
          content: 'Question',
        );
        final firstReply = ChatMessage(
          id: 'reply-1',
          parentId: root.id,
          role: MessageRole.assistant,
          content: 'First reply',
        );
        final activeReply = ChatMessage(
          id: 'reply-2',
          parentId: root.id,
          role: MessageRole.assistant,
          content: 'Second reply',
        );
        final branched = Conversation(
          id: 'branched',
          messages: [root, firstReply, activeReply],
          activeChildren: {kRootKey: root.id, root.id: activeReply.id},
        );
        final json = _MemoryRepository(name: 'json', conversations: [branched]);
        final drift = _MemoryRepository(name: 'drift');

        await migrateLegacyJsonToDrift(drift, json: json);

        final migrated = drift.conversations.single;
        expect(migrated.messages, same(branched.messages));
        expect(migrated.activeChildren, same(branched.activeChildren));
      },
    );
  });
}

class _RecordingRepository implements ConversationRepository {
  _RecordingRepository({
    required this.name,
    required this.delegate,
    required this.events,
  });

  final String name;
  final ConversationRepository delegate;
  final List<String> events;

  @override
  Future<List<Conversation>> loadAll() {
    events.add('$name.loadAll');
    return delegate.loadAll();
  }

  @override
  Future<void> saveAll(List<Conversation> conversations) {
    events.add('$name.saveAll');
    return delegate.saveAll(conversations);
  }

  @override
  Future<void> saveConversation(Conversation conversation) =>
      delegate.saveConversation(conversation);

  @override
  Future<void> deleteConversation(String id) => delegate.deleteConversation(id);
}

class _MemoryRepository implements ConversationRepository {
  _MemoryRepository({
    required this.name,
    List<Conversation>? conversations,
    List<String>? events,
    this.failSaveAll = false,
  }) : conversations = conversations ?? [],
       events = events ?? [];

  final String name;
  List<Conversation> conversations;
  final List<String> events;
  final bool failSaveAll;

  @override
  Future<List<Conversation>> loadAll() async {
    events.add('$name.loadAll');
    return conversations;
  }

  @override
  Future<void> saveAll(List<Conversation> conversations) async {
    events.add('$name.saveAll');
    if (failSaveAll) throw StateError('save failed');
    this.conversations = conversations;
  }

  @override
  Future<void> saveConversation(Conversation conversation) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteConversation(String id) async {
    throw UnimplementedError();
  }
}
