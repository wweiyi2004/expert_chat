import 'dart:convert';

/// Negotiated v1 extension. A cursor mismatch requires an authoritative full
/// snapshot; clients never guess whether a missed append was already applied.
Map<String, Object?> bridgeSnapshotPatch(
  Map<String, Object?> before,
  Map<String, Object?> after,
  int base,
  int cursor,
) {
  const rows = {'messages', 'steps', 'agents'};
  bool equal(Object? a, Object? b) =>
      identical(a, b) || jsonEncode(a) == jsonEncode(b);
  final arrays = <String, Object?>{};
  for (final name in rows) {
    if (equal(before[name], after[name])) continue;
    final old = {
      for (final row in before[name] as List? ?? [])
        (row as Map)['id'] as String: Map<String, Object?>.from(row),
    };
    final updates = <Map<String, Object?>>[];
    final order = <String>[];
    for (final raw in after[name] as List? ?? []) {
      final value = Map<String, Object?>.from(raw as Map),
          id = value['id'] as String;
      order.add(id);
      final previous = old.remove(id);
      if (previous == null) {
        updates.add({'id': id, 'replace': value});
        continue;
      }
      if (equal(previous, value)) continue;
      final fields = <String, Object?>{}, append = <String, String>{};
      for (final entry in value.entries) {
        if (equal(previous[entry.key], entry.value)) continue;
        final prior = previous[entry.key], next = entry.value;
        if (name == 'messages' &&
            const {'text', 'thinking'}.contains(entry.key) &&
            prior is String &&
            next is String &&
            next.startsWith(prior)) {
          append[entry.key] = next.substring(prior.length);
        } else {
          fields[entry.key] = next;
        }
      }
      updates.add({
        'id': id,
        'fields': fields,
        'append': append,
        'remove': [
          for (final key in previous.keys)
            if (!value.containsKey(key)) key,
        ],
      });
    }
    arrays[name] = {
      'updates': updates,
      'remove': old.keys.toList(),
      'order': order,
    };
  }
  return {
    'base': base,
    'cursor': cursor,
    'fields': {
      for (final entry in after.entries)
        if (!rows.contains(entry.key) && !equal(before[entry.key], entry.value))
          entry.key: entry.value,
    },
    'remove': [
      for (final key in before.keys)
        if (!after.containsKey(key)) key,
    ],
    'arrays': arrays,
  };
}
