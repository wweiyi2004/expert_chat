import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'cache_clear_result.dart';

class AppCacheService {
  AppCacheService({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getTemporaryDirectory;

  final Future<Directory> Function() _directoryProvider;

  static final _ownedPreviewName = RegExp(
    r'^expert_chat_preview_\d+\.html$',
    caseSensitive: false,
  );

  /// Removes only files with the app's exact preview prefix. On desktop,
  /// getTemporaryDirectory may be shared by other applications, so deleting
  /// the directory itself or arbitrary children would be unsafe.
  Future<CacheClearResult> clearOwnedTemporaryFiles() async {
    final root = await _directoryProvider();
    if (!await root.exists()) return const CacheClearResult();

    var files = 0;
    var bytes = 0;
    var failures = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last;
      if (!_ownedPreviewName.hasMatch(name)) continue;
      try {
        final size = await entity.length();
        await entity.delete();
        files++;
        bytes += size;
      } catch (_) {
        failures++;
      }
    }
    return CacheClearResult(
      filesRemoved: files,
      bytesRemoved: bytes,
      failures: failures,
    );
  }
}
