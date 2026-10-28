import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// The caller owns the state-directory lock. Preserve old bytes on failure.
Future<void> writeAtomic(File target, List<int> bytes) async {
  await target.parent.create(recursive: true);
  final temp = File(
    '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    final handle = await temp.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    if (Platform.isWindows) {
      using((arena) {
        if (MoveFileEx(
              temp.path.toNativeUtf16(allocator: arena),
              target.path.toNativeUtf16(allocator: arena),
              MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            ) ==
            0) {
          throw FileSystemException(
            'Atomic replacement failed',
            target.path,
            OSError('', GetLastError()),
          );
        }
      });
    } else {
      await temp.rename(target.path);
    }
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}
