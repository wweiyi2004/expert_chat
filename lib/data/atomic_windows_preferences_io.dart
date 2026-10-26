import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

typedef _MoveFileNative =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _MoveFileDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);

/// Installs only over the actual Windows plugin, preserving test/mocked stores.
/// Existing keys, prefixes and the on-disk location/JSON format are unchanged.
Future<void> installAtomicWindowsPreferences() async {
  if (!Platform.isWindows) return;
  final current = SharedPreferencesStorePlatform.instance;
  if (current is AtomicWindowsPreferencesStore ||
      current.runtimeType != SharedPreferencesWindows) {
    return;
  }
  final directory = await getApplicationSupportDirectory();
  SharedPreferencesStorePlatform
      .instance = await AtomicWindowsPreferencesStore.open(
    File('${directory.path}${Platform.pathSeparator}shared_preferences.json'),
  );
}

/// The legacy Windows plugin truncates its destination before writing. This
/// application-owned store writes and flushes a private temporary file, then
/// replaces the destination atomically. A failed write never touches old bytes.
class AtomicWindowsPreferencesStore extends SharedPreferencesStorePlatform {
  AtomicWindowsPreferencesStore._(
    this.file,
    this._values,
    this._writeTemporary,
    this._replace,
  );
  final File file;
  final Map<String, Object> _values;
  final Future<void> Function(File, List<int>) _writeTemporary;
  final Future<void> Function(File, File) _replace;
  Future<void> _pending = Future<void>.value();
  static int _temporarySequence = 0;

  static Future<AtomicWindowsPreferencesStore> open(
    File file, {
    Future<void> Function(File, List<int>)? writeTemporary,
    Future<void> Function(File, File)? replace,
  }) async {
    final values = <String, Object>{};
    if (await file.exists()) {
      final text = await file.readAsString();
      if (text.trim().isEmpty) {
        throw StateError('偏好文件为空，已保留原文件；请从已核验备份恢复后重试。');
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        throw const FormatException('偏好文件 JSON 损坏，已保留原文件；请核验备份后恢复。');
      }
      if (decoded is! Map) throw const FormatException('偏好文件格式无效；未覆盖原文件');
      values.addAll(Map<String, Object>.from(decoded));
    }
    return AtomicWindowsPreferencesStore._(
      file,
      values,
      writeTemporary ??
          (temporary, bytes) async {
            final handle = await temporary.open(mode: FileMode.write);
            try {
              await handle.writeFrom(bytes);
              await handle.flush();
            } finally {
              await handle.close();
            }
          },
      replace ?? _replaceWindows,
    );
  }

  static Future<void> _replaceWindows(File source, File destination) async {
    if (!Platform.isWindows) {
      await source.rename(destination.path);
      return;
    }
    final kernel = DynamicLibrary.open('kernel32.dll');
    final move = kernel.lookupFunction<_MoveFileNative, _MoveFileDart>(
      'MoveFileExW',
    );
    final getError = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final from = source.path.toNativeUtf16(),
        to = destination.path.toNativeUtf16();
    try {
      // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH. No delete/truncate
      // of destination occurs before this single Windows replacement operation.
      if (move(from, to, 0x1 | 0x8) == 0) {
        final code = getError();
        throw FileSystemException(
          'Atomic preferences replacement failed',
          destination.path,
          OSError('Windows error', code),
        );
      }
    } finally {
      calloc.free(from);
      calloc.free(to);
    }
  }

  Future<void> flush() => _pending;

  Object _copy(Object value) =>
      value is List ? List<String>.from(value) : value;
  Map<String, Object> _snapshot() => {
    for (final e in _values.entries) e.key: _copy(e.value),
  };
  Future<bool> _save() {
    final snapshot = _snapshot();
    final result = _pending.catchError((Object _) {}).then((_) async {
      final temporary = File(
        '${file.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}.${_temporarySequence++}',
      );
      try {
        final bytes = utf8.encode(jsonEncode(snapshot));
        await file.parent.create(recursive: true);
        await _writeTemporary(temporary, bytes);
        for (var attempt = 1; ; attempt++) {
          try {
            await _replace(temporary, file);
            break;
          } on FileSystemException catch (error) {
            // A Windows reader/antivirus can briefly deny replacement. The
            // flushed temporary stays intact and the old destination remains
            // untouched through every bounded replacement attempt.
            if (attempt >= 3 ||
                !{5, 32, 33}.contains(error.osError?.errorCode)) {
              rethrow;
            }
            await Future<void>.delayed(
              Duration(milliseconds: attempt == 1 ? 10 : 30),
            );
          }
        }
        return true;
      } catch (error) {
        // Do not log keys/values or arbitrary error messages containing data.
        final code = error is FileSystemException
            ? error.osError?.errorCode
            : null;
        debugPrint(
          'Atomic preferences save failed: ${error.runtimeType}${code == null ? '' : ' (OS $code)'}',
        );
        return false;
      } finally {
        // Only this operation's uniquely named temporary file is removable.
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _values[key] = _copy(value);
    return _save();
  }

  @override
  Future<bool> remove(String key) {
    _values.remove(key);
    return _save();
  }

  @override
  Future<bool> clear() => clearWithPrefix('flutter.');
  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );
  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    final f = parameters.filter;
    _values.removeWhere(
      (key, _) =>
          key.startsWith(f.prefix) &&
          (f.allowList == null || f.allowList!.contains(key)),
    );
    return _save();
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithPrefix('flutter.');
  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: prefix)),
      );
  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final f = parameters.filter;
    return _snapshot()..removeWhere(
      (key, _) =>
          !key.startsWith(f.prefix) ||
          (f.allowList != null && !f.allowList!.contains(key)),
    );
  }
}
