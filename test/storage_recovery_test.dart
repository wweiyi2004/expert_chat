import 'dart:convert';
import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late DriftConversationRepository repo;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = DriftConversationRepository(db);
    await repo.saveConversation(
      Conversation(
        id: 'c',
        messages: [
          ChatMessage(id: 'm', role: MessageRole.user, content: 'original'),
        ],
      ),
    );
  });
  tearDown(() => db.close());

  test(
    'partial attachment recovery preserves exact original through save and reload',
    () async {
      final raw = jsonEncode([
        {'id': 'good', 'name': 'valid.txt', 'sizeBytes': 10, 'text': 'valid'},
        {'id': 'damaged', 'name': 'damaged.txt', 'sizeBytes': 'not a number'},
      ]);
      await db.customStatement(
        'UPDATE messages SET attachments_json = ? WHERE id = ?',
        [raw, 'm'],
      );
      final c = await repo.loadConversation('c');
      expect(c.messages.single.attachments.single.name, 'valid.txt');
      expect(c.messages.single.recoveredStorage['attachments_json'], raw);
      final copied = Conversation.fromJson(c.toJson()).copyWith(
        title: 'renamed',
        messages: [
          c.messages.single.copyWith(content: 'edited text'),
          ChatMessage(
            id: 'new',
            role: MessageRole.assistant,
            content: 'new answer',
          ),
        ],
      );
      await repo.saveConversation(copied);
      await repo.renameConversation('c', 'metadata only', DateTime.now());
      final rows = await db
          .customSelect(
            "SELECT attachments_json,content FROM messages WHERE id='m'",
          )
          .getSingle();
      expect(rows.read<String>('attachments_json'), raw);
      expect(rows.read<String>('content'), 'edited text');
      final reloaded = await repo.loadConversation('c');
      expect(reloaded.messages.first.attachments.single.id, 'good');
      expect(reloaded.messages, hasLength(2));
    },
  );

  test(
    'malformed object and header JSON survive placeholders and full writes',
    () async {
      await db.customStatement(
        "UPDATE conversations SET local_cast_json = '{broken', active_children_json = '[1]' WHERE id='c'",
      );
      await db.customStatement(
        "UPDATE messages SET long_task_json = '{broken', citations_json = '[4]' WHERE id='m'",
      );
      final placeholder = (await repo.loadSummaries()).single.toPlaceholder();
      expect(placeholder.recoveredStorage, hasLength(2));
      await repo.saveConversation(placeholder.copyWith(title: 'renamed'));
      final loaded = await repo.loadConversation('c');
      expect(loaded.messages.single.longTask, isNull);
      expect(loaded.messages.single.recoveredStorage, hasLength(2));
      await repo.saveConversation(loaded);
      final header = await db.select(db.conversations).getSingle();
      final message = await db.select(db.messages).getSingle();
      expect(header.localCastJson, '{broken');
      expect(header.activeChildrenJson, '[1]');
      expect(message.longTaskJson, '{broken');
      expect(message.citationsJson, '[4]');
      await repo.deleteConversation('c');
      await repo.renameConversation('c', 'must not resurrect', DateTime.now());
      expect(await repo.loadSummaries(), isEmpty);
    },
  );

  testWidgets('unreadable message fields have a visible recovery notice', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.user,
              content: 'kept',
              recoveredStorage: const {'attachments_json': '{bad'},
            ),
            isStreaming: false,
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('storage-recovery-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('原始数据已保留'), findsOneWidget);
  });
}
