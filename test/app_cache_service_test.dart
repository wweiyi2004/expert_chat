import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:expert_chat/domain/cache/app_cache_service.dart';

void main() {
  test('removes only app-owned preview files', () async {
    final root = await Directory.systemTemp.createTemp(
      'expert_chat_cache_test_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final owned = File(
      '${root.path}${Platform.pathSeparator}'
      'expert_chat_preview_123.html',
    );
    final unrelated = File(
      '${root.path}${Platform.pathSeparator}'
      'another_app_cache.tmp',
    );
    await owned.writeAsString('owned cache');
    await unrelated.writeAsString('must survive');

    final result = await AppCacheService(
      directoryProvider: () async => root,
    ).clearOwnedTemporaryFiles();

    expect(await owned.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(result.filesRemoved, 1);
    expect(result.bytesRemoved, greaterThan(0));
    expect(result.failures, 0);
  });

  test(
    'counts only successfully deleted bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'expert_chat_cache_test_',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final deletable = File(
        '${root.path}${Platform.pathSeparator}expert_chat_preview_1.html',
      );
      await deletable.writeAsString('ok');
      final locked = File(
        '${root.path}${Platform.pathSeparator}expert_chat_preview_2.html',
      );
      await locked.writeAsString('locked by another process');
      // Windows enforces an exclusive lock on open files — the same failure
      // mode as a browser or AV scanner holding the preview file.
      final handle = await locked.open(mode: FileMode.append);
      addTearDown(handle.close);

      final result = await AppCacheService(
        directoryProvider: () async => root,
      ).clearOwnedTemporaryFiles();

      expect(result.filesRemoved, 1);
      expect(result.failures, 1);
      expect(result.bytesRemoved, 'ok'.length);
    },
    skip: Platform.isWindows ? false : 'relies on Windows file locking',
  );
}
