import 'dart:convert';
import 'dart:io';
import 'paths_host.dart';
import 'atomic_file.dart';

/// Same on-disk keys as the Flutter legacy preference API; one host owns writes.
class SharedPreferences {
  SharedPreferences._(this.file, this._values);
  final File file;
  final Map<String, Object> _values;
  Future<void> _tail = Future.value();
  static Map<String, Object>? _mock;
  static final _instances = <String, Future<SharedPreferences>>{};
  static SharedPreferences? _mockInstance;
  static Future<void> resetStatic() async {
    _mock = null;
    _mockInstance = null;
    _instances.clear();
  }

  static void setMockInitialValues(Map<String, Object> values) {
    _mock = {
      for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
    };
    _mockInstance = null;
  }

  static Future<SharedPreferences> getInstance() async {
    if (_mock case final values?) {
      return _mockInstance ??= SharedPreferences._(
        File('in-memory-preferences'),
        values,
      );
    }
    final file = File(
      '${(await getApplicationSupportDirectory()).path}/shared_preferences.json',
    );
    return _instances.putIfAbsent(file.path, () => _open(file));
  }

  static Future<SharedPreferences> _open(File file) async {
    final values = <String, Object>{};
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException(
          'Invalid preferences; preserved original file',
        );
      }
      values.addAll(Map<String, Object>.from(decoded));
    }
    return SharedPreferences._(file, values);
  }

  Object? get(String key) => _values['flutter.$key'];
  String? getString(String key) => get(key) as String?;
  bool? getBool(String key) => get(key) as bool?;
  int? getInt(String key) => get(key) as int?;
  double? getDouble(String key) => (get(key) as num?)?.toDouble();
  List<String>? getStringList(String key) =>
      (get(key) as List?)?.cast<String>().toList();
  bool containsKey(String key) => _values.containsKey('flutter.$key');
  Set<String> getKeys() => _values.keys
      .where((k) => k.startsWith('flutter.'))
      .map((k) => k.substring(8))
      .toSet();
  Future<bool> compareAndSet(String key, Object? expected, Object? value) =>
      _change(key, value, checkExpected: true, expected: expected);
  Future<bool> _change(
    String? key,
    Object? value, {
    bool clear = false,
    bool checkExpected = false,
    Object? expected,
  }) async {
    final operation = _tail.then((_) async {
      if (checkExpected && jsonEncode(get(key!)) != jsonEncode(expected)) {
        throw StateError('Preference changed');
      }
      final next = Map<String, Object>.from(_values);
      if (clear) {
        next.removeWhere((k, _) => k.startsWith('flutter.'));
      } else if (value == null) {
        next.remove('flutter.$key');
      } else {
        next['flutter.$key'] = value;
      }
      if (!identical(_values, _mock)) {
        await writeAtomic(file, utf8.encode(jsonEncode(next)));
      }
      _values
        ..clear()
        ..addAll(next);
    });
    _tail = operation.catchError((Object _) {});
    await operation;
    return true;
  }

  Future<bool> setString(String key, String value) => _change(key, value);
  Future<bool> setBool(String key, bool value) => _change(key, value);
  Future<bool> setInt(String key, int value) => _change(key, value);
  Future<bool> setDouble(String key, double value) => _change(key, value);
  Future<bool> setStringList(String key, List<String> value) =>
      _change(key, List<String>.from(value));
  Future<bool> remove(String key) => _change(key, null);
  Future<bool> clear() => _change(null, null, clear: true);
  Future<void> reload() async {
    await _tail;
    if (identical(_values, _mock)) return;
    final fresh = await _open(file);
    _values
      ..clear()
      ..addAll(fresh._values);
  }
}
