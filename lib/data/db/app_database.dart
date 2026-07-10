import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Conversation header row. Messages live in [Messages] and cascade-delete.
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text().withDefault(const Constant('新对话'))();
  DateTimeColumn get updatedAt => dateTime()();
  // JSON map parentId→activeChildId driving branch selection (v2).
  TextColumn get activeChildrenJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// One chat message. Rich sub-objects (attachments, citations) are stored as
/// JSON strings to keep the schema flat; they are (de)serialized in the repo.
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get convoId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  // Tree parent node id; null for a root-level message (v2).
  TextColumn get parentId => text().nullable()();
  TextColumn get role => text()();
  TextColumn get content => text()();
  TextColumn get reasoning => text().withDefault(const Constant(''))();
  TextColumn get model => text().nullable()();
  IntColumn get thinkingMillis => integer().withDefault(const Constant(0))();
  TextColumn get attachmentsJson => text().nullable()();
  TextColumn get citationsJson => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  // Monotonic ordering within a conversation (insertion order).
  IntColumn get seq => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Conversations, Messages])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(messages, messages.parentId);
        await m.addColumn(conversations, conversations.activeChildrenJson);
        // v1 conversations were linear (ordered by `seq`); v2 is a tree
        // keyed by parentId. Without backfilling, every old message keeps a
        // NULL parentId and becomes a root sibling, so activePath (which
        // walks one child per node) collapses the whole history to a single
        // message. Re-link each message to its predecessor by seq.
        await customStatement(
          'UPDATE messages SET parent_id = ('
          ' SELECT m2.id FROM messages AS m2'
          ' WHERE m2.convo_id = messages.convo_id AND m2.seq < messages.seq'
          ' ORDER BY m2.seq DESC LIMIT 1'
          ') WHERE parent_id IS NULL',
        );
      }
    },
    beforeOpen: (details) async {
      // SQLite has FK enforcement off by default; needed for cascade delete.
      await customStatement('PRAGMA foreign_keys = ON');
      // Keep the conversation list and per-conversation history reads
      // indexed as the local archive grows. IF NOT EXISTS makes this safe
      // for both fresh installs and already-migrated databases.
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_conversations_updated_at '
        'ON conversations (updated_at DESC)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_messages_convo_id_seq '
        'ON messages (convo_id, seq)',
      );
    },
  );

  static QueryExecutor _open() => driftDatabase(name: 'expert_chat');
}
