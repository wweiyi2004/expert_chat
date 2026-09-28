import 'dart:convert';
import '../../data/db/app_database.dart' show GenerationRecord;

/// Version identity is derived from recorded parent links, never prompt text
/// or duplicated image bytes. Filtering does not change version numbers.
class GenerationCatalog {
  GenerationCatalog(List<GenerationRecord> records)
    : records = List.unmodifiable(records),
      byId = {for (final record in records) record.id: record} {
    final ordered = [...records]
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    final added = <String>{};
    for (final record in ordered) {
      final path = <GenerationRecord>[];
      final visiting = <String>{};
      GenerationRecord? cursor = record;
      while (cursor != null &&
          !added.contains(cursor.id) &&
          visiting.add(cursor.id)) {
        path.add(cursor);
        cursor = byId[cursor.parentGenerationId];
      }
      for (final entry in path.reversed) {
        if (!added.add(entry.id)) continue;
        final family = series.putIfAbsent(seriesId(entry.id), () => []);
        family.add(entry);
        labels[entry.id] = '版本 ${family.length}';
      }
    }
  }

  final List<GenerationRecord> records;
  final Map<String, GenerationRecord> byId;
  final Map<String, String> labels = {};
  final Map<String, List<GenerationRecord>> series = {};
  final Map<String, String> _roots = {};

  String seriesId(String id) {
    if (_roots.containsKey(id)) return _roots[id]!;
    final path = <String>[];
    final seen = <String>{};
    var cursor = id;
    while (true) {
      if (_roots.containsKey(cursor)) {
        cursor = _roots[cursor]!;
        break;
      }
      if (!seen.add(cursor)) {
        // Imported malformed cycles still get a deterministic, bounded group.
        final cycle = path.sublist(path.indexOf(cursor))..sort();
        cursor = cycle.first;
        break;
      }
      path.add(cursor);
      final parent = byId[cursor]?.parentGenerationId;
      if (parent == null || parent.isEmpty) break;
      cursor = parent;
    }
    for (final member in path) {
      _roots[member] = cursor;
    }
    return cursor;
  }

  List<GenerationRecord> filter({String query = '', String? family}) {
    final needle = query.trim().toLowerCase();
    return records
        .where(
          (r) =>
              (family == null || seriesId(r.id) == family) &&
              (needle.isEmpty ||
                  '${r.originalPrompt}\n${r.optimizedPrompt}\n${r.model}'
                      .toLowerCase()
                      .contains(needle)),
        )
        .toList();
  }

  String relationship(GenerationRecord record) {
    if (record.parentGenerationId == null) return '首次生成';
    final label = labels[record.parentGenerationId];
    return label == null ? '来源版本不在记录中' : '基于 $label';
  }

  static Map<String, String> parameters(GenerationRecord r) => {
    '原始描述': r.originalPrompt,
    '实际提示词': r.optimizedPrompt,
    'API 修订描述': r.revisedPrompt ?? '',
    '模型': r.model,
    '服务': r.providerHost,
    '尺寸': r.imageSize,
    '参考图': _references(r.referencesJson),
  };

  static Set<String> changedFields(GenerationRecord a, GenerationRecord b) {
    final left = parameters(a);
    final right = parameters(b);
    return {
      for (final key in left.keys)
        if (left[key] != right[key]) key,
    };
  }

  static String _references(String raw) {
    try {
      final rows = jsonDecode(raw) as List;
      return jsonEncode([
        for (final row in rows)
          (row as Map)['sha256'] ?? row['libraryItemId'] ?? row,
      ]);
    } catch (_) {
      return raw;
    }
  }
}
