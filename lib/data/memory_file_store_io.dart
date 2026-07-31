import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'memory_repository.dart';

/// Native Markdown store under the app-support sandbox.
class MemoryFileStore implements MemoryStore {
  MemoryFileStore(SharedPreferences? _, {this._filePath});

  /// Overrides the sandboxed location (used by tests).
  final String? _filePath;

  Future<File> _file() async {
    final injected = _filePath;
    if (injected != null) {
      await File(injected).parent.create(recursive: true);
      return File(injected);
    }
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
    if (await file.exists()) return file.readAsString();
    // The main file may be missing because a write moved it to the backup
    // just before the process died. Without this fallback the backup would
    // hold the only committed copy and a later write would delete it.
    final backup = File('${file.path}.bak');
    if (await backup.exists()) {
      final markdown = await backup.readAsString();
      // A live write always keeps the temp file around between moving the
      // main file aside and putting the fresh revision in place, so only
      // restore the backup into the main slot when no write is in flight.
      final temp = File('${file.path}.tmp');
      if (!await temp.exists()) {
        try {
          await backup.rename(file.path);
        } catch (_) {
          // Renaming is only a convenience; the content is already read.
        }
      }
      return markdown;
    }
    return null;
  }

  @override
  Future<void> write(String markdown) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temp.writeAsString(markdown, flush: true);

    var movedOriginal = false;
    try {
      if (await file.exists()) {
        await file.rename(backup.path);
        movedOriginal = true;
      }
      await temp.rename(file.path);
      // The fresh revision is now the main file, so the stale backup is no
      // longer the only copy and can be cleaned up. Deleting it before the
      // rotation would leave the backup as the only copy if the process
      // died in the middle.
      try {
        if (await backup.exists()) await backup.delete();
      } catch (_) {
        // A leftover backup is harmless: reads prefer the main file and the
        // next successful write replaces it.
      }
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
