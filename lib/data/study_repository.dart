import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/study/study_prompt_assembler.dart';
import '../domain/study/tutor_style.dart';
import 'db/app_database.dart';
import 'study_models.dart';

const legacyStudyLibraryKey = 'studyLibrary.v1';
const _studyDriftMigrationKey = 'studyLibrary.drift.v1';

const _courseKind = 'course';
const _nodeKind = 'node';
const _cardKind = 'card';
const _wrongKind = 'wrong';

/// Drift-backed study library. Domain entities are stored as individual rows,
/// while session metadata is relational and cascades with conversations.
class StudyRepository {
  StudyRepository(this._db, this._prefs);

  final AppDatabase _db;
  final SharedPreferences _prefs;
  Future<void>? _migration;

  Future<StudyLibrary> load() async {
    await _ensureMigrated();
    return _loadFromDb();
  }

  Future<void> save(StudyLibrary library) async {
    await _ensureMigrated();
    await _db.transaction(() => _saveToDb(library));
  }

  /// Read-modify-write inside one SQLite transaction. Concurrent study actions
  /// therefore see the latest committed library instead of overwriting one
  /// another from stale Riverpod snapshots.
  Future<StudyLibrary> update(
    StudyLibrary Function(StudyLibrary current) mutate,
  ) async {
    await _ensureMigrated();
    late StudyLibrary next;
    await _db.transaction(() async {
      next = mutate(await _loadFromDb());
      await _saveToDb(next);
    });
    return next;
  }

  Future<StudySessionMeta?> getSession(String conversationId) async {
    await _ensureMigrated();
    final row = await (_db.select(
      _db.studySessions,
    )..where((s) => s.conversationId.equals(conversationId))).getSingleOrNull();
    return row == null ? null : _sessionFromRow(row);
  }

  Future<void> _ensureMigrated() async {
    final active = _migration;
    if (active != null) return active;
    final started = _migrateLegacyData();
    _migration = started;
    try {
      await started;
    } catch (_) {
      _migration = null;
      rethrow;
    }
  }

  Future<void> _migrateLegacyData() async {
    if (_prefs.getBool(_studyDriftMigrationKey) == true) return;

    StudyLibrary? legacy;
    final raw = _prefs.getString(legacyStudyLibraryKey);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          legacy = StudyLibrary.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Keep a corrupt legacy value for possible manual recovery. Valid
        // legacy author-note metadata is still migrated below.
      }
    }

    await _db.transaction(() async {
      if (legacy != null) await _mergeLegacyLibrary(legacy);
      await _migrateLegacyAuthorNotes();
    });

    final marked = await _prefs.setBool(_studyDriftMigrationKey, true);
    if (!marked) throw StateError('无法记录学习数据迁移状态');
    if (legacy != null) await _prefs.remove(legacyStudyLibraryKey);
  }

  Future<void> _mergeLegacyLibrary(StudyLibrary library) async {
    final now = DateTime.now();
    await _upsertEntities(
      _courseKind,
      library.courses.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    await _upsertEntities(
      _nodeKind,
      library.nodes.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    await _upsertEntities(
      _cardKind,
      library.cards.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    await _upsertEntities(
      _wrongKind,
      library.wrongItems.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    for (final session in library.sessions) {
      await _upsertSessionIfConversationExists(session);
    }
  }

  Future<void> _migrateLegacyAuthorNotes() async {
    final conversations = await (_db.select(
      _db.conversations,
    )..where((c) => c.mode.equals('study'))).get();
    for (final conversation in conversations) {
      final map = StudyPromptAssembler.decodeSessionNote(
        conversation.authorNote,
      );
      if (map == null) continue;
      final session = StudySessionMeta.fromJson({
        ...map,
        'conversationId': conversation.id,
        'createdAt': conversation.updatedAt.toIso8601String(),
      });
      await _upsertSessionIfConversationExists(session);

      final cleaned = conversation.authorNote
          .split('\n')
          .where((line) => !line.trim().startsWith('study_meta:'))
          .join('\n')
          .trim();
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversation.id)))
          .write(ConversationsCompanion(authorNote: Value(cleaned)));
    }
  }

  Future<StudyLibrary> _loadFromDb() async {
    final rows = await (_db.select(
      _db.studyEntities,
    )..orderBy([(e) => OrderingTerm.asc(e.sortIndex)])).get();
    final courses = <StudyCourse>[];
    final nodes = <StudyNode>[];
    final cards = <StudyCard>[];
    final wrongItems = <StudyWrongItem>[];
    for (final row in rows) {
      try {
        final decoded = jsonDecode(row.payloadJson);
        if (decoded is! Map) continue;
        final map = Map<String, dynamic>.from(decoded);
        switch (row.kind) {
          case _courseKind:
            courses.add(StudyCourse.fromJson(map));
          case _nodeKind:
            nodes.add(StudyNode.fromJson(map));
          case _cardKind:
            cards.add(StudyCard.fromJson(map));
          case _wrongKind:
            wrongItems.add(StudyWrongItem.fromJson(map));
        }
      } catch (_) {
        // One damaged row must not hide the rest of the user's study library.
      }
    }
    final sessionRows = await _db.select(_db.studySessions).get();
    return StudyLibrary(
      courses: courses,
      nodes: nodes,
      cards: cards,
      wrongItems: wrongItems,
      sessions: sessionRows.map(_sessionFromRow).toList(),
    );
  }

  Future<void> _saveToDb(StudyLibrary library) async {
    final now = DateTime.now();
    await _syncEntities(
      _courseKind,
      library.courses.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    await _syncEntities(
      _nodeKind,
      library.nodes.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    await _syncEntities(
      _cardKind,
      library.cards.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );
    await _syncEntities(
      _wrongKind,
      library.wrongItems.map((e) => (id: e.id, json: e.toJson())).toList(),
      now,
    );

    final sessionIds = library.sessions.map((s) => s.conversationId).toList();
    if (sessionIds.isEmpty) {
      await _db.delete(_db.studySessions).go();
    } else {
      await (_db.delete(
        _db.studySessions,
      )..where((s) => s.conversationId.isNotIn(sessionIds))).go();
    }
    for (final session in library.sessions) {
      await _upsertSessionIfConversationExists(session);
    }
  }

  Future<void> _syncEntities(
    String kind,
    List<({String id, Map<String, dynamic> json})> entities,
    DateTime now,
  ) async {
    final ids = entities.map((e) => e.id).toList();
    final deletion = _db.delete(_db.studyEntities)
      ..where((e) => e.kind.equals(kind));
    if (ids.isNotEmpty) deletion.where((e) => e.id.isNotIn(ids));
    await deletion.go();
    await _upsertEntities(kind, entities, now);
  }

  Future<void> _upsertEntities(
    String kind,
    List<({String id, Map<String, dynamic> json})> entities,
    DateTime now,
  ) async {
    if (entities.isEmpty) return;
    await _db.batch((batch) {
      for (var index = 0; index < entities.length; index++) {
        final entity = entities[index];
        batch.insert(
          _db.studyEntities,
          StudyEntitiesCompanion.insert(
            kind: kind,
            id: entity.id,
            payloadJson: jsonEncode(entity.json),
            sortIndex: Value(index),
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => StudyEntitiesCompanion(
              payloadJson: Value(jsonEncode(entity.json)),
              sortIndex: Value(index),
              updatedAt: Value(now),
            ),
          ),
        );
      }
    });
  }

  Future<void> _upsertSessionIfConversationExists(
    StudySessionMeta session,
  ) async {
    final exists =
        await (_db.selectOnly(_db.conversations)
              ..addColumns([_db.conversations.id])
              ..where(_db.conversations.id.equals(session.conversationId)))
            .getSingleOrNull();
    if (exists == null) return;
    await _db
        .into(_db.studySessions)
        .insertOnConflictUpdate(
          StudySessionsCompanion.insert(
            conversationId: session.conversationId,
            path: session.path.wire,
            tutorStyle: session.tutorStyle.wire,
            topic: Value(session.topic),
            courseId: Value(session.courseId),
            nodeId: Value(session.nodeId),
            createdAt: session.createdAt,
          ),
        );
  }

  StudySessionMeta _sessionFromRow(StudySessionRow row) => StudySessionMeta(
    conversationId: row.conversationId,
    path: StudyPath.fromWire(row.path),
    tutorStyle: TutorStyle.fromWire(row.tutorStyle),
    topic: row.topic,
    courseId: row.courseId,
    nodeId: row.nodeId,
    createdAt: row.createdAt,
  );
}
