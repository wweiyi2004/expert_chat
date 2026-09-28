import 'dart:convert';

/// Reads independent records without confusing an unreadable value with a
/// deletion. The exact original field is retained until an explicit repair.
class StoredJsonReader {
  final Map<String, String> retained = {};

  List<T> list<T>(String field, String? raw, T Function(dynamic) decode) {
    if (raw == null || raw.isEmpty) return const [];
    final values = <T>[];
    try {
      for (final item in jsonDecode(raw) as List) {
        try {
          values.add(decode(item));
        } catch (_) {
          retained[field] = raw;
        }
      }
    } catch (_) {
      retained[field] = raw;
    }
    return values;
  }

  T? object<T>(String field, String? raw, T Function(dynamic) decode) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return decode(jsonDecode(raw));
    } catch (_) {
      retained[field] = raw;
      return null;
    }
  }

  Map<String, String> stringMap(String field, String? raw) =>
      object(field, raw, (value) => Map<String, String>.from(value as Map)) ??
      {};
}
