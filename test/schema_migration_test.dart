import 'package:drift_dev/api/migrations_native.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated_migrations/schema.dart';

void main() {
  test(
    'published v15 schema upgrades to the checked v17 schema without data loss',
    () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final schema = await verifier.schemaAt(15);
      schema.rawDatabase.execute(
        'INSERT INTO conversations(id,title,updated_at,active_children_json) VALUES (?,?,?,?)',
        ['legacy', 'Before upgrade', 1700000000, '{"":"user","user":"answer"}'],
      );
      schema.rawDatabase.execute(
        'INSERT INTO messages(id,convo_id,role,content,created_at,seq) VALUES (?,?,?,?,?,?)',
        ['user', 'legacy', 'user', '历史问题', 1700000000, 0],
      );
      schema.rawDatabase.execute(
        'INSERT INTO messages(id,convo_id,parent_id,role,content,created_at,seq) VALUES (?,?,?,?,?,?,?)',
        ['answer', 'legacy', 'user', 'assistant', '历史答案', 1700000001, 1],
      );
      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 17);
      final messages = await db.select(db.messages).get();
      expect(messages.map((m) => m.content), containsAll(['历史问题', '历史答案']));
      expect(messages.last.parentId, 'user');
      final header = await db.select(db.conversations).getSingle();
      expect(header.activeChildrenJson, '{"":"user","user":"answer"}');
      expect(header.projectId, isNull);
      expect(await db.select(db.projects).get(), isEmpty);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    },
  );

  test(
    'v16 generation parameters survive migration with unknown protocol',
    () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final schema = await verifier.schemaAt(16);
      schema.rawDatabase.execute(
        '''
      INSERT INTO generation_records
      (id,conversation_id,message_id,original_prompt,optimized_prompt,revised_prompt,
       model,provider_host,image_size,references_json,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ''',
        [
          'generation',
          'conversation',
          'message',
          '原始描述',
          '发送描述',
          '返回描述',
          'gemini-2.5-flash-image',
          'https://media.example',
          '1024x1024',
          '[{"libraryItemId":"reference","sha256":"synthetic-hash"}]',
          1700000000,
        ],
      );
      final db = AppDatabase(schema.newConnection());
      addTearDown(db.close);
      await verifier.migrateAndValidate(db, 17);
      final record = await db.select(db.generationRecords).getSingle();
      expect(
        record.apiFormat,
        isNull,
        reason: 'The model name cannot reveal the original protocol',
      );
      expect(record.id, 'generation');
      expect(record.conversationId, 'conversation');
      expect(record.messageId, 'message');
      expect(record.originalPrompt, '原始描述');
      expect(record.optimizedPrompt, '发送描述');
      expect(record.revisedPrompt, '返回描述');
      expect(record.model, 'gemini-2.5-flash-image');
      expect(record.providerHost, 'https://media.example');
      expect(record.imageSize, '1024x1024');
      expect(
        record.referencesJson,
        '[{"libraryItemId":"reference","sha256":"synthetic-hash"}]',
      );
      expect(record.createdAt.millisecondsSinceEpoch, 1700000000000);
      expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
    },
  );

  test('new installation matches the versioned schema', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final db = AppDatabase(await verifier.startAt(17));
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 17);
  });
}
