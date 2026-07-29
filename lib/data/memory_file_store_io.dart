import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'memory_repository.dart';

/// Native Markdown store under the app-support sandbox.
class MemoryFileStore implements MemoryStore {
  MemoryFileStore(SharedPreferences _);

  Future<File> _file() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}memories',
    );
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}global.memory.md');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String markdown) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temp.writeAsString(markdown, flush: true);

    var movedOriginal = false;
    try {
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) {
        await file.rename(backup.path);
        movedOriginal = true;
      }
      await temp.rename(file.path);
    } catch (_) {
      if (movedOriginal && !await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Future<String> locationLabel() async => (await _file()).path;
}
