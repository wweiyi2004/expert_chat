import 'package:drift_dev/api/migrations_native.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'generated_migrations/schema.dart';

void main() {
  test(
    'published v15 schema upgrades to the checked v16 schema without data loss',
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
      await verifier.migrateAndValidate(db, 16);
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

  test('new installation matches the versioned schema', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final db = AppDatabase(await verifier.startAt(16));
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 16);
  });
}
