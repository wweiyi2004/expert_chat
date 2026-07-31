import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart' hide Conversation;
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('story-local cast round-trips through JSON and copyWith', () {
    final createdAt = DateTime.utc(2026, 2, 1);
    final updatedAt = DateTime.utc(2026, 2, 2);
    final card = CharacterCard(
      id: 'local-detective',
      name: '林默',
      description: '调查失踪案的私家侦探',
      personality: '冷静、谨慎',
      scenario: '雨夜港口',
      firstMes: '雾里有人。',
      exampleDialogs: '林默：别碰那扇门。',
      systemPrompt: '言简意赅地演绎林默。',
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
    final conversation = Conversation(
      id: 'story',
      mode: ConversationMode.ensemble,
      participantIds: const ['local-detective'],
      localCast: [card],
      updatedAt: updatedAt,
    );

    final restored = Conversation.fromJson(conversation.toJson());

    expect(restored.localCast, hasLength(1));
    expect(restored.localCast.single.id, 'local-detective');
    expect(restored.localCast.single.name, '林默');
    expect(restored.localCast.single.description, card.description);
    expect(restored.localCast.single.personality, card.personality);
    expect(restored.localCast.single.scenario, card.scenario);
    expect(restored.localCast.single.firstMes, card.firstMes);
    expect(restored.localCast.single.exampleDialogs, card.exampleDialogs);
    expect(restored.localCast.single.systemPrompt, card.systemPrompt);
    expect(restored.localCast.single.createdAt, createdAt);
    expect(restored.localCast.single.updatedAt, updatedAt);

    final replacement = CharacterCard(id: 'local-witness', name: '目击者');
    expect(
      conversation.copyWith(localCast: [replacement]).localCast.single.id,
      'local-witness',
    );

    // Conversations serialized before localCast existed remain valid.
    expect(
      Conversation.fromJson(const {'id': 'legacy-story'}).localCast,
      isEmpty,
    );
  });

  test(
    'persists story-local cast without adding it to the global library',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftConversationRepository(db);
      final timestamp = DateTime.utc(2026, 3, 1);
      final conversation = Conversation(
        id: 'generated-story',
        title: '海上失踪案',
        mode: ConversationMode.ensemble,
        participantIds: const ['captain', 'doctor'],
        localCast: [
          CharacterCard(
            id: 'captain',
            name: '船长',
            personality: '固执但重情',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
          CharacterCard(
            id: 'doctor',
            name: '医生',
            systemPrompt: '隐藏自己的真实目的。',
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        ],
        updatedAt: timestamp,
      );

      await repo.saveConversation(conversation);
      final loaded = (await repo.loadAll()).single;

      expect(loaded.localCast.map((card) => card.id), ['captain', 'doctor']);
      expect(loaded.localCast.first.personality, '固执但重情');
      expect(loaded.localCast.last.systemPrompt, '隐藏自己的真实目的。');
      expect(await db.select(db.characterCards).get(), isEmpty);
    },
  );

  test(
    'migrates a v4 conversation database with an empty local cast',
    () async {
      final executor = NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('''
          CREATE TABLE conversations (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '新对话',
            updated_at INTEGER NOT NULL,
            active_children_json TEXT NULL,
            mode TEXT NOT NULL DEFAULT 'chat',
            character_id TEXT NULL,
            world_info_ids_json TEXT NULL,
            outline TEXT NOT NULL DEFAULT '',
            author_note TEXT NOT NULL DEFAULT '',
            plot_cursor INTEGER NOT NULL DEFAULT 0,
            participant_ids_json TEXT NULL,
            venue TEXT NOT NULL DEFAULT '',
            next_speaker_index INTEGER NOT NULL DEFAULT 0
          )
        ''');
          rawDb.execute('''
          CREATE TABLE messages (
            id TEXT NOT NULL PRIMARY KEY,
            convo_id TEXT NOT NULL REFERENCES conversations (id)
              ON DELETE CASCADE,
            parent_id TEXT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            reasoning TEXT NOT NULL DEFAULT '',
            model TEXT NULL,
            thinking_millis INTEGER NOT NULL DEFAULT 0,
            attachments_json TEXT NULL,
            citations_json TEXT NULL,
            created_at INTEGER NOT NULL,
            seq INTEGER NOT NULL DEFAULT 0,
            speaker_id TEXT NULL,
            speaker_name TEXT NULL
          )
        ''');
          rawDb.execute('''
          CREATE TABLE character_cards (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            personality TEXT NOT NULL DEFAULT '',
            scenario TEXT NOT NULL DEFAULT '',
            first_mes TEXT NOT NULL DEFAULT '',
            example_dialogs TEXT NOT NULL DEFAULT '',
            system_prompt TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
          rawDb.execute('''
          CREATE TABLE world_info_entries (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            keys_json TEXT NOT NULL DEFAULT '[]',
            content TEXT NOT NULL DEFAULT '',
            always_on INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            priority INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
          rawDb.execute(
            "INSERT INTO conversations (id, title, updated_at, mode) "
            "VALUES ('old-story', '旧故事', 0, 'story')",
          );
          rawDb.execute('PRAGMA user_version = 4');
        },
      );
      final db = AppDatabase(executor);
      addTearDown(db.close);

      final columns = await db
          .customSelect('PRAGMA table_info(conversations)')
          .get();
      expect(
        columns.map((row) => row.read<String>('name')),
        contains('local_cast_json'),
      );

      final loaded = (await DriftConversationRepository(db).loadAll()).single;
      expect(loaded.id, 'old-story');
      expect(loaded.title, '旧故事');
      expect(loaded.localCast, isEmpty);
    },
  );

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

  test('migrates v8 schema adding target_total_chars', () async {
    final executor = NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('''
          CREATE TABLE conversations (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '新对话',
            updated_at INTEGER NOT NULL,
            active_children_json TEXT NULL,
            mode TEXT NOT NULL DEFAULT 'chat',
            character_id TEXT NULL,
            world_info_ids_json TEXT NULL,
            outline TEXT NOT NULL DEFAULT '',
            author_note TEXT NOT NULL DEFAULT '',
            plot_cursor INTEGER NOT NULL DEFAULT 0,
            participant_ids_json TEXT NULL,
            venue TEXT NOT NULL DEFAULT '',
            next_speaker_index INTEGER NOT NULL DEFAULT 0,
            local_cast_json TEXT NULL
          )
        ''');
        rawDb.execute('''
          CREATE TABLE messages (
            id TEXT NOT NULL PRIMARY KEY,
            convo_id TEXT NOT NULL REFERENCES conversations (id)
              ON DELETE CASCADE,
            parent_id TEXT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            reasoning TEXT NOT NULL DEFAULT '',
            model TEXT NULL,
            thinking_millis INTEGER NOT NULL DEFAULT 0,
            attachments_json TEXT NULL,
            citations_json TEXT NULL,
            created_at INTEGER NOT NULL,
            seq INTEGER NOT NULL DEFAULT 0,
            speaker_id TEXT NULL,
            speaker_name TEXT NULL,
            kind TEXT NOT NULL DEFAULT 'text',
            search_activities_json TEXT NULL,
            applied_world_info_json TEXT NULL
          )
        ''');
        rawDb.execute('''
          CREATE TABLE character_cards (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            personality TEXT NOT NULL DEFAULT '',
            scenario TEXT NOT NULL DEFAULT '',
            first_mes TEXT NOT NULL DEFAULT '',
            example_dialogs TEXT NOT NULL DEFAULT '',
            system_prompt TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        rawDb.execute('''
          CREATE TABLE world_info_entries (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            keys_json TEXT NOT NULL DEFAULT '[]',
            content TEXT NOT NULL DEFAULT '',
            always_on INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            priority INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        rawDb.execute(
          "INSERT INTO conversations (id, title, updated_at, mode) "
          "VALUES ('pre-v9', '待升级', 0, 'story')",
        );
        rawDb.execute('PRAGMA user_version = 8');
      },
    );
    final db = AppDatabase(executor);
    addTearDown(db.close);

    final columns = await db
        .customSelect('PRAGMA table_info(conversations)')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      contains('target_total_chars'),
    );
    final loaded = (await DriftConversationRepository(db).loadAll()).single;
    expect(loaded.id, 'pre-v9');
    expect(loaded.targetTotalChars, 0);
  });

  test('persists targetTotalChars across reload', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftConversationRepository(db);
    final timestamp = DateTime.utc(2026, 7, 1);
    await repo.saveConversation(
      Conversation(
        id: 'budget-story',
        title: '八万字',
        mode: ConversationMode.story,
        targetTotalChars: 80000,
        updatedAt: timestamp,
      ),
    );
    final loaded = (await repo.loadAll()).single;
    expect(loaded.targetTotalChars, 80000);
  });

  test('search treats user % and _ as literal characters', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftConversationRepository(db);
    final base = DateTime.utc(2026, 6, 1);
    await repo.saveConversation(
      Conversation(
        id: 'percent',
        title: '进度',
        messages: [
          ChatMessage(
            id: 'p1',
            role: MessageRole.assistant,
            content: '任务完成 100%,继续下一步',
            createdAt: base,
          ),
          ChatMessage(
            id: 'p2',
            role: MessageRole.user,
            content: '剩余 50%',
            createdAt: base.add(const Duration(seconds: 1)),
          ),
        ],
        updatedAt: base,
      ),
    );
    await repo.saveConversation(
      Conversation(
        id: 'underscore',
        title: '文件',
        messages: [
          ChatMessage(
            id: 'u1',
            role: MessageRole.user,
            content: '下载 progress_1.apk 后解压',
            createdAt: base,
          ),
        ],
        updatedAt: base.add(const Duration(seconds: 2)),
      ),
    );
    await repo.saveConversation(
      Conversation(
        id: 'dashlike',
        title: '其他',
        messages: [
          ChatMessage(
            id: 'd1',
            role: MessageRole.assistant,
            content: '下载 progressX1.apk 失败',
            createdAt: base,
          ),
        ],
        updatedAt: base.add(const Duration(seconds: 3)),
      ),
    );

    // 未转义时查询里的 % 是通配符,会命中所有消息;转义后只命中字面 "100%"。
    final percent = await repo.search('100%');
    expect(percent.map((c) => c.id).toSet(), {'percent'});

    // _ 同理:只命中字面 "progress_1",不命中 "progressX1"。
    final underscore = await repo.search('progress_1');
    expect(underscore.map((c) => c.id).toSet(), {'underscore'});
  });

  test('does not rewrite a row whose stored kind is unknown to this build', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftConversationRepository(db);
    final timestamp = DateTime.utc(2026, 8, 1);
    // 模拟未来版本写入的未知 kind 行:旧版本读到后会降级成 text。
    await db.into(db.conversations).insert(
      ConversationsCompanion.insert(
        id: 'future-convo',
        title: const Value('future'),
        updatedAt: timestamp,
      ),
    );
    await db.into(db.messages).insert(
      MessagesCompanion.insert(
        id: 'future-msg',
        convoId: 'future-convo',
        role: 'assistant',
        content: '来自未来版本的消息',
        createdAt: timestamp,
        kind: const Value('futureKind'),
      ),
    );
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

    final loaded = (await repo.loadAll()).single;
    expect(loaded.messages.single.kind, MessageKind.text);

    // 整库回存不得重写未知 kind 的行,否则会把 kind 静默降级为 text 并持久化。
    await repo.saveConversation(loaded);
    expect(await _auditOperations(db), isEmpty);

    final row = await (db.select(
      db.messages,
    )..where((m) => m.id.equals('future-msg'))).getSingle();
    expect(row.kind, 'futureKind');
  });

  test('persists message kind across reload', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = DriftConversationRepository(db);
    final timestamp = DateTime.utc(2026, 4, 1);
    final prompt = ChatMessage(
      id: 'prompt',
      role: MessageRole.user,
      content: '画一只猫',
      createdAt: timestamp,
    );
    final image = ChatMessage(
      id: 'image',
      role: MessageRole.assistant,
      parentId: 'prompt',
      content: '图片已生成',
      kind: MessageKind.generatedImage,
      createdAt: timestamp,
    );

    await repo.saveConversation(
      Conversation(
        id: 'image-convo',
        title: '生图',
        messages: [prompt, image],
        updatedAt: timestamp,
      ),
    );
    final loaded = (await repo.loadAll()).single;

    expect(loaded.messages.first.kind, MessageKind.text);
    expect(loaded.messages.last.kind, MessageKind.generatedImage);
  });

  test('migrates a v5 database adding the message kind column', () async {
    final executor = NativeDatabase.memory(
      setup: (rawDb) {
        rawDb.execute('''
          CREATE TABLE conversations (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '新对话',
            updated_at INTEGER NOT NULL,
            active_children_json TEXT NULL,
            mode TEXT NOT NULL DEFAULT 'chat',
            character_id TEXT NULL,
            world_info_ids_json TEXT NULL,
            outline TEXT NOT NULL DEFAULT '',
            author_note TEXT NOT NULL DEFAULT '',
            plot_cursor INTEGER NOT NULL DEFAULT 0,
            participant_ids_json TEXT NULL,
            venue TEXT NOT NULL DEFAULT '',
            next_speaker_index INTEGER NOT NULL DEFAULT 0,
            local_cast_json TEXT NULL
          )
        ''');
        rawDb.execute('''
          CREATE TABLE messages (
            id TEXT NOT NULL PRIMARY KEY,
            convo_id TEXT NOT NULL REFERENCES conversations (id)
              ON DELETE CASCADE,
            parent_id TEXT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            reasoning TEXT NOT NULL DEFAULT '',
            model TEXT NULL,
            thinking_millis INTEGER NOT NULL DEFAULT 0,
            attachments_json TEXT NULL,
            citations_json TEXT NULL,
            created_at INTEGER NOT NULL,
            seq INTEGER NOT NULL DEFAULT 0,
            speaker_id TEXT NULL,
            speaker_name TEXT NULL
          )
        ''');
        rawDb.execute('''
          CREATE TABLE character_cards (
            id TEXT NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            personality TEXT NOT NULL DEFAULT '',
            scenario TEXT NOT NULL DEFAULT '',
            first_mes TEXT NOT NULL DEFAULT '',
            example_dialogs TEXT NOT NULL DEFAULT '',
            system_prompt TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        rawDb.execute('''
          CREATE TABLE world_info_entries (
            id TEXT NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            keys_json TEXT NOT NULL DEFAULT '[]',
            content TEXT NOT NULL DEFAULT '',
            always_on INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            priority INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        rawDb.execute(
          "INSERT INTO conversations (id, title, updated_at) "
          "VALUES ('old-chat', '旧会话', 0)",
        );
        rawDb.execute(
          "INSERT INTO messages (id, convo_id, role, content, created_at) "
          "VALUES ('old-reply', 'old-chat', 'assistant', '旧回复', 0)",
        );
        rawDb.execute('PRAGMA user_version = 5');
      },
    );
    final db = AppDatabase(executor);
    addTearDown(db.close);

    final columns = await db.customSelect('PRAGMA table_info(messages)').get();
    expect(columns.map((row) => row.read<String>('name')), contains('kind'));

    final loaded = (await DriftConversationRepository(db).loadAll()).single;
    expect(loaded.messages.single.kind, MessageKind.text);
  });
}

Future<List<String>> _auditOperations(AppDatabase db) async {
  final rows = await db
      .customSelect('SELECT operation FROM message_audit ORDER BY rowid')
      .get();
  return rows.map((row) => row.read<String>('operation')).toList();
}
