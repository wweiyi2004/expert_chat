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

  // Story mode fields (v3).
  TextColumn get mode => text().withDefault(const Constant('chat'))();
  TextColumn get characterId => text().nullable()();
  TextColumn get worldInfoIdsJson => text().nullable()();
  TextColumn get outline => text().withDefault(const Constant(''))();
  TextColumn get authorNote => text().withDefault(const Constant(''))();
  IntColumn get plotCursor => integer().withDefault(const Constant(0))();

  // Ensemble / multi-character (v4).
  TextColumn get participantIdsJson => text().nullable()();
  TextColumn get venue => text().withDefault(const Constant(''))();
  IntColumn get nextSpeakerIndex => integer().withDefault(const Constant(0))();

  // Story-local, AI-generated character cards (v5).
  TextColumn get localCastJson => text().nullable()();

  // Director novel target length in Chinese characters (v9). 0 = unset.
  IntColumn get targetTotalChars => integer().withDefault(const Constant(0))();

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
  // Ensemble speaker (v4).
  TextColumn get speakerId => text().nullable()();
  TextColumn get speakerName => text().nullable()();
  // MessageKind wire name, e.g. generated-image bubbles (v6).
  TextColumn get kind => text().withDefault(const Constant('text'))();
  // Web-search process steps shown in the bubble (v7).
  TextColumn get searchActivitiesJson => text().nullable()();
  // World-info entries injected for this story turn (v8).
  TextColumn get appliedWorldInfoJson => text().nullable()();
  // Durable server-side document-processing job metadata (v11).
  TextColumn get longTaskJson => text().nullable()();
  // Per-turn skill route persisted on the assistant message (v12).
  TextColumn get turnSkillJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Character card library (v3).
@DataClassName('CharacterCardRow')
class CharacterCards extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get personality => text().withDefault(const Constant(''))();
  TextColumn get scenario => text().withDefault(const Constant(''))();
  TextColumn get firstMes => text().withDefault(const Constant(''))();
  TextColumn get exampleDialogs => text().withDefault(const Constant(''))();
  TextColumn get systemPrompt => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Global world-info / lorebook entries (v3).
@DataClassName('WorldInfoEntryRow')
class WorldInfoEntries extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get keysJson => text().withDefault(const Constant('[]'))();
  TextColumn get content => text().withDefault(const Constant(''))();
  BoolColumn get alwaysOn => boolean().withDefault(const Constant(false))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Granular study-domain entities (v10). Each course, node, card, and wrong
/// item gets its own row so one small update no longer rewrites the complete
/// study library blob.
@DataClassName('StudyEntityRow')
class StudyEntities extends Table {
  TextColumn get kind => text()();
  TextColumn get id => text()();
  TextColumn get payloadJson => text()();
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {kind, id};
}

/// Canonical metadata for study conversations (v10). Conversation deletion
/// cascades to the metadata row, avoiding orphan session records.
@DataClassName('StudySessionRow')
class StudySessions extends Table {
  TextColumn get conversationId =>
      text().references(Conversations, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  TextColumn get tutorStyle => text()();
  TextColumn get topic => text().withDefault(const Constant(''))();
  TextColumn get courseId => text().nullable()();
  TextColumn get nodeId => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

@DriftDatabase(
  tables: [
    Conversations,
    Messages,
    CharacterCards,
    WorldInfoEntries,
    StudyEntities,
    StudySessions,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _open());

  @override
  int get schemaVersion => 12;

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
      if (from < 3) {
        await m.addColumn(conversations, conversations.mode);
        await m.addColumn(conversations, conversations.characterId);
        await m.addColumn(conversations, conversations.worldInfoIdsJson);
        await m.addColumn(conversations, conversations.outline);
        await m.addColumn(conversations, conversations.authorNote);
        await m.addColumn(conversations, conversations.plotCursor);
        await m.createTable(characterCards);
        await m.createTable(worldInfoEntries);
      }
      if (from < 4) {
        await m.addColumn(conversations, conversations.participantIdsJson);
        await m.addColumn(conversations, conversations.venue);
        await m.addColumn(conversations, conversations.nextSpeakerIndex);
        await m.addColumn(messages, messages.speakerId);
        await m.addColumn(messages, messages.speakerName);
      }
      if (from < 5) {
        await m.addColumn(conversations, conversations.localCastJson);
      }
      if (from < 6) {
        await m.addColumn(messages, messages.kind);
      }
      if (from < 7) {
        await m.addColumn(messages, messages.searchActivitiesJson);
      }
      if (from < 8) {
        await m.addColumn(messages, messages.appliedWorldInfoJson);
      }
      if (from < 9) {
        await m.addColumn(conversations, conversations.targetTotalChars);
      }
      if (from < 10) {
        await m.createTable(studyEntities);
        await m.createTable(studySessions);
      }
      if (from < 11) {
        await m.addColumn(messages, messages.longTaskJson);
      }
      if (from < 12) {
        await m.addColumn(messages, messages.turnSkillJson);
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
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_character_cards_updated_at '
        'ON character_cards (updated_at DESC)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_world_info_priority '
        'ON world_info_entries (priority DESC, updated_at DESC)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_study_entities_kind_updated '
        'ON study_entities (kind, updated_at DESC)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_study_sessions_course_node '
        'ON study_sessions (course_id, node_id)',
      );
    },
  );

  static QueryExecutor _open() => driftDatabase(name: 'expert_chat');
}
