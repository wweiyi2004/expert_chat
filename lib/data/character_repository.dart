import 'package:drift/drift.dart';

import 'db/app_database.dart';
import 'story_models.dart';

class CharacterRepository {
  CharacterRepository(this._db);

  final AppDatabase _db;

  Future<List<CharacterCard>> loadAll() async {
    final rows = await (_db.select(
      _db.characterCards,
    )..orderBy([(c) => OrderingTerm.desc(c.updatedAt)])).get();
    return rows.map(_toCard).toList();
  }

  Future<CharacterCard?> getById(String id) async {
    final row = await (_db.select(
      _db.characterCards,
    )..where((c) => c.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toCard(row);
  }

  Future<void> save(CharacterCard card) async {
    await _db
        .into(_db.characterCards)
        .insertOnConflictUpdate(
          CharacterCardsCompanion.insert(
            id: card.id,
            name: card.name,
            description: Value(card.description),
            personality: Value(card.personality),
            scenario: Value(card.scenario),
            firstMes: Value(card.firstMes),
            exampleDialogs: Value(card.exampleDialogs),
            systemPrompt: Value(card.systemPrompt),
            createdAt: card.createdAt,
            updatedAt: card.updatedAt,
          ),
        );
  }

  Future<void> delete(String id) =>
      (_db.delete(_db.characterCards)..where((c) => c.id.equals(id))).go();

  CharacterCard _toCard(CharacterCardRow row) => CharacterCard(
    id: row.id,
    name: row.name,
    description: row.description,
    personality: row.personality,
    scenario: row.scenario,
    firstMes: row.firstMes,
    exampleDialogs: row.exampleDialogs,
    systemPrompt: row.systemPrompt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}
