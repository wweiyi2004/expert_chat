import 'dart:ffi';
import 'dart:io';

DynamicLibrary openPtyLibrary() {
  final override = Platform.environment['FLUTTER_PTY2_LIBRARY'];
  if (override case final path? when path.isNotEmpty) {
    return DynamicLibrary.open(path);
  }
  if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isLinux || Platform.isAndroid) {
    return DynamicLibrary.open('libflutter_pty2.so');
  }
  if (Platform.isWindows) return DynamicLibrary.open('flutter_pty2.dll');
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}
