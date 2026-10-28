import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';
import '../domain/host/host_client.dart';
import '../domain/host/wire_models.dart';
import '../data/library_file_store.dart';
import '../data/memory_repository.dart';
import 'package:crypto/crypto.dart';

class HostPreferenceStore extends SharedPreferencesStorePlatform {
  HostPreferenceStore(this.client);
  final HostClient client;
  final _cache = <String, Object>{};
  Future<void> refresh() async {
    final response = await client.invoke('host.preferences.read', {});
    _cache
      ..clear()
      ..addAll({
        for (final e in wireMap(response['values']).entries)
          'flutter.${e.key}': e.value as Object,
      });
  }

  String _key(String key) {
    if (!key.startsWith('flutter.')) {
      throw StateError('Unexpected preference namespace');
    }
    return key.substring(8);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    try {
      await client.invoke('host.preferences.write', {
        'key': _key(key),
        'value': value,
        'has_expected': true,
        'expected': _cache[key],
      });
      _cache[key] = value;
      return true;
    } catch (_) {
      if (client.connected) await refresh();
      rethrow;
    }
  }

  @override
  Future<bool> remove(String key) async {
    try {
      await client.invoke('host.preferences.remove', {
        'key': _key(key),
        'has_expected': true,
        'expected': _cache[key],
      });
      _cache.remove(key);
      return true;
    } catch (_) {
      if (client.connected) await refresh();
      rethrow;
    }
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
    await refresh();
    final filter = parameters.filter;
    return Map.fromEntries(
      _cache.entries.where(
        (e) =>
            e.key.startsWith(filter.prefix) &&
            (filter.allowList == null || filter.allowList!.contains(e.key)),
      ),
    );
  }

  @override
  Future<bool> clear() => clearWithPrefix('flutter.');
  @override
  Future<bool> clearWithPrefix(String prefix) => clearWithParameters(
    ClearParameters(filter: PreferencesFilter(prefix: prefix)),
  );
  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final keys = (await getAllWithParameters(
      GetAllParameters(filter: parameters.filter),
    )).keys.toList();
    for (final key in keys) {
      await remove(key);
    }
    return true;
  }
}

class HostCredentialStore extends FlutterSecureStoragePlatform {
  HostCredentialStore(this.client);
  final HostClient client;
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      (await client.invoke('host.credentials.read', {'key': key}))['value']
          as String?;
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map<String, String>.from(
    (await client.invoke('host.credentials.readAll', {}))['values'] as Map,
  );
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => await read(key: key, options: options) != null;
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    await client.invoke('host.credentials.write', {'key': key, 'value': value});
  }

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    await client.invoke('host.credentials.remove', {'key': key});
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    await client.invoke('host.credentials.removeAll', {'confirmed': true});
  }
}

class HostLibraryFiles extends LibraryFileStore {
  HostLibraryFiles(this.client);
  final HostClient client;
  @override
  Future<String> get rootPath async =>
      (await client.invoke('host.library.root', {}))['path'] as String;
  @override
  Future<String> writeBytes({
    required String id,
    required String fileName,
    required bool image,
    required Uint8List bytes,
  }) async =>
      (await client.invoke('host.library.write', {
            'id': id,
            'fileName': fileName,
            'image': image,
            'bytes': base64Encode(bytes),
          }))['path']
          as String;
  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final value =
        (await client.invoke('host.library.read', {
              'path': relativePath,
            }))['bytes']
            as String?;
    return value == null ? null : base64Decode(value);
  }

  @override
  Future<void> delete(String relativePath) async {
    await client.invoke('host.library.delete', {'path': relativePath});
  }
}

class HostMemoryFiles extends MemoryStore {
  HostMemoryFiles(this.client);
  final HostClient client;
  String? _expectedHash;
  @override
  Future<String?> read() async {
    final response = await client.invoke('host.memory.read', {});
    _expectedHash = response['sha256'] as String;
    return response['markdown'] as String?;
  }

  @override
  Future<void> write(String markdown) async {
    if (_expectedHash == null) await read();
    await client.invoke('host.memory.write', {
      'markdown': markdown,
      'expected': _expectedHash,
    });
    _expectedHash = sha256.convert(utf8.encode(markdown)).toString();
  }

  @override
  Future<String> locationLabel() async =>
      (await client.invoke('host.memory.location', {}))['path'] as String;
}
