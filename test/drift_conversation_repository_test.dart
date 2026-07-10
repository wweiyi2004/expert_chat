import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'synchronizes only changed message rows and creates archive indexes',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftConversationRepository(db);
      final timestamp = DateTime.utc(2026, 1, 1);
      final first = ChatMessage(
        id: 'first',
        role: MessageRole.user,
        content: 'first message',
        createdAt: timestamp,
      );
      final second = ChatMessage(
        id: 'second',
        role: MessageRole.assistant,
        content: 'second message',
        createdAt: timestamp,
      );
      final conversation = Conversation(
        id: 'conversation',
        title: 'Archive',
        messages: [first, second],
        updatedAt: timestamp,
      );

      await repo.saveConversation(conversation);
      await db.customStatement(
        'CREATE TABLE message_audit (operation TEXT NOT NULL)',
      );
      await db.customStatement(
        "CREATE TRIGGER messages_after_insert AFTER INSERT ON messages "
        "BEGIN INSERT INTO message_audit VALUES ('insert'); END",
      );
      await db.customStatement(
        "CREATE TRIGGER messages_after_update AFTER UPDATE ON messages "
        "BEGIN INSERT INTO message_audit VALUES ('update'); END",
      );
      await db.customStatement(
        "CREATE TRIGGER messages_after_delete AFTER DELETE ON messages "
        "BEGIN INSERT INTO message_audit VALUES ('delete'); END",
      );

      // An unchanged snapshot must not rewrite any message rows.
      await repo.saveConversation(conversation);
      expect(await _auditOperations(db), isEmpty);

      await db.customStatement('DELETE FROM message_audit');
      final changedSecond = ChatMessage(
        id: second.id,
        role: second.role,
        content: 'changed message',
        createdAt: second.createdAt,
      );
      await repo.saveConversation(
        Conversation(
          id: conversation.id,
          title: conversation.title,
          messages: [first, changedSecond],
          updatedAt: conversation.updatedAt,
        ),
      );
      expect(await _auditOperations(db), ['update']);

      await db.customStatement('DELETE FROM message_audit');
      await repo.saveConversation(
        Conversation(
          id: conversation.id,
          title: conversation.title,
          messages: [first],
          updatedAt: conversation.updatedAt,
        ),
      );
      expect(await _auditOperations(db), ['delete']);

      final indexRows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name IN ('idx_conversations_updated_at', 'idx_messages_convo_id_seq')",
          )
          .get();
      expect(indexRows.map((row) => row.read<String>('name')).toSet(), {
        'idx_conversations_updated_at',
        'idx_messages_convo_id_seq',
      });
    },
  );
}

Future<List<String>> _auditOperations(AppDatabase db) async {
  final rows = await db
      .customSelect('SELECT operation FROM message_audit ORDER BY rowid')
      .get();
  return rows.map((row) => row.read<String>('operation')).toList();
}
