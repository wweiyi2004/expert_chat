import 'dart:convert';

import 'package:drift/drift.dart';

import 'db/app_database.dart';
import 'story_models.dart';

class WorldInfoRepository {
  WorldInfoRepository(this._db);

  final AppDatabase _db;

  Future<List<WorldInfoEntry>> loadAll() async {
    final rows =
        await (_db.select(_db.worldInfoEntries)..orderBy([
              (e) => OrderingTerm.desc(e.priority),
              (e) => OrderingTerm.desc(e.updatedAt),
            ]))
            .get();
    return rows.map(_toEntry).toList();
  }

  Future<List<WorldInfoEntry>> loadByIds(Iterable<String> ids) async {
    final idList = ids.toList();
    if (idList.isEmpty) return const [];
    final rows = await (_db.select(
      _db.worldInfoEntries,
    )..where((e) => e.id.isIn(idList))).get();
    final byId = {for (final row in rows) row.id: _toEntry(row)};
    return [
      for (final id in idList)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> save(WorldInfoEntry entry) async {
    await _db
        .into(_db.worldInfoEntries)
        .insertOnConflictUpdate(
          WorldInfoEntriesCompanion.insert(
            id: entry.id,
            title: entry.title,
            keysJson: Value(jsonEncode(entry.keys)),
            content: Value(entry.content),
            alwaysOn: Value(entry.alwaysOn),
            enabled: Value(entry.enabled),
            priority: Value(entry.priority),
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
          ),
        );
  }

  Future<void> delete(String id) =>
      (_db.delete(_db.worldInfoEntries)..where((e) => e.id.equals(id))).go();

  WorldInfoEntry _toEntry(WorldInfoEntryRow row) {
    List<String> keys;
    try {
      keys = (jsonDecode(row.keysJson) as List<dynamic>)
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      keys = const [];
    }
    return WorldInfoEntry(
      id: row.id,
      title: row.title,
      keys: keys,
      content: row.content,
      alwaysOn: row.alwaysOn,
      enabled: row.enabled,
      priority: row.priority,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }
}
