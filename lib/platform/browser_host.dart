import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'dart:ffi';

enum LaunchMode { platformDefault, externalApplication }

Future<bool> launchUrl(
  Uri url, {
  LaunchMode mode = LaunchMode.externalApplication,
}) async {
  if (!['https', 'http'].contains(url.scheme)) {
    throw ArgumentError('Only browser URLs are supported');
  }
  if (!Platform.isWindows) {
    throw UnsupportedError('Configure an external browser adapter');
  }
  return using(
    (arena) =>
        ShellExecute(
          0,
          'open'.toNativeUtf16(allocator: arena),
          url.toString().toNativeUtf16(allocator: arena),
          nullptr,
          nullptr,
          SW_SHOWNORMAL,
        ) >
        32,
  );
}
