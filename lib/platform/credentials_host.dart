import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'paths_host.dart';
import 'atomic_file.dart';
import 'legacy_credentials.dart';

/// Plain-Dart adapter for the existing Windows plugin's DPAPI JSON format.
/// No credential bytes are returned to diagnostics or untrusted task tools.
const _cryptProtectUiForbidden = 0x1;

class FlutterSecureStorage {
  const FlutterSecureStorage();
  static Map<String, String>? _mock;
  static void setMockInitialValues(Map<String, String> values) =>
      _mock = Map.of(values);
  static Future<void> _writes = Future.value();
  Future<void> migrateLegacy() async {
    if (_mock != null ||
        !Platform.isWindows ||
        HostPaths.stateDirectory != null ||
        Platform.environment.containsKey('EXPERT_HOST_DATA_DIR')) {
      return;
    }
    final operation = _writes.then((_) async {
      final file = await _file();
      final marker = File('${file.parent.path}/host/credentials-migrated.v1');
      if (await marker.exists()) return;
      final existing = await _load();
      final legacy = await readLegacyCredentials(file.parent);
      if (legacy.isNotEmpty) {
        if (await file.exists()) {
          final backup = File(
            '${file.parent.path}/host/pre-host-credentials.dpapi',
          );
          if (!await backup.exists()) {
            await backup.parent.create(recursive: true);
            await file.copy(backup.path);
          }
        }
        final plain = utf8.encode(jsonEncode({...legacy, ...existing}));
        try {
          await writeAtomic(file, _crypt(plain, encrypt: true));
        } finally {
          plain.fillRange(0, plain.length, 0);
        }
      }
      await writeAtomic(marker, utf8.encode('1\n'));
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}/flutter_secure_storage.dat',
  );
  static Uint8List _crypt(List<int> input, {required bool encrypt}) {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows credential backend required');
    }
    return using((arena) {
      final bytes = arena<Uint8>(input.length);
      bytes.asTypedList(input.length).setAll(0, input);
      final source = arena<CRYPT_INTEGER_BLOB>()..ref.cbData = input.length;
      source.ref.pbData = bytes;
      final output = arena<CRYPT_INTEGER_BLOB>();
      final success = encrypt
          ? CryptProtectData(
              source,
              nullptr,
              nullptr,
              nullptr,
              nullptr,
              _cryptProtectUiForbidden,
              output,
            )
          : CryptUnprotectData(
              source,
              nullptr,
              nullptr,
              nullptr,
              nullptr,
              _cryptProtectUiForbidden,
              output,
            );
      if (success == 0) {
        throw StateError(
          'Credential encryption/decryption failed; original file preserved',
        );
      }
      try {
        return Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData),
        );
      } finally {
        bytes.asTypedList(input.length).fillRange(0, input.length, 0);
        if (!encrypt) {
          output.ref.pbData
              .asTypedList(output.ref.cbData)
              .fillRange(0, output.ref.cbData, 0);
        }
        LocalFree(output.ref.pbData);
      }
    });
  }

  Future<Map<String, String>> _load() async {
    if (_mock case final values?) return Map.of(values);
    final file = await _file();
    if (!await file.exists()) return {};
    final plain = _crypt(await file.readAsBytes(), encrypt: false);
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map ||
          decoded.entries.any((e) => e.key is! String || e.value is! String)) {
        throw const FormatException(
          'Credential storage is invalid; original file preserved',
        );
      }
      return Map<String, String>.from(decoded);
    } catch (_) {
      throw const FormatException(
        'Credential storage is invalid; original file preserved',
      );
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<String?> read({required String key}) async {
    await _writes;
    return (await _load())[key];
  }

  Future<Map<String, String>> readAll() async {
    await _writes;
    return _load();
  }

  Future<bool> containsKey({required String key}) async =>
      (await readAll()).containsKey(key);
  Future<void> _mutate(void Function(Map<String, String>) change) {
    final operation = _writes.then((_) async {
      final values = await _load();
      change(values);
      if (_mock != null) {
        _mock = values;
        return;
      }
      final plain = utf8.encode(jsonEncode(values));
      try {
        await writeAtomic(await _file(), _crypt(plain, encrypt: true));
      } finally {
        plain.fillRange(0, plain.length, 0);
      }
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> write({required String key, required String? value}) =>
      _mutate((map) {
        if (value == null) {
          map.remove(key);
        } else {
          map[key] = value;
        }
      });
  Future<void> delete({required String key}) =>
      _mutate((map) => map.remove(key));
  Future<void> deleteAll() => _mutate((map) => map.clear());
}
