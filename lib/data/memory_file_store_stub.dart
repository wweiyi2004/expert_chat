import 'package:shared_preferences/shared_preferences.dart';

import 'memory_repository.dart';

/// Browser fallback. Native platforms use a real Markdown file; Web keeps the
/// exact same Markdown document in browser-local preferences.
class MemoryFileStore implements MemoryStore {
  MemoryFileStore(this._prefs);

  static const _key = 'memory.global.markdown';
  final SharedPreferences _prefs;

  @override
  Future<String?> read() async => _prefs.getString(_key);

  @override
  Future<void> write(String markdown) async {
    final ok = await _prefs.setString(_key, markdown);
    if (!ok) throw Exception('浏览器未能保存记忆。');
  }

  @override
  Future<String> locationLabel() async => '浏览器本地存储';
}
