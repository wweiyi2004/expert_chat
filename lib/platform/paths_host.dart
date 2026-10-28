import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

class HostPaths {
  static String? stateDirectory;
  static String? assetsDirectory;
  static String get bundleDirectory {
    final directory = p.dirname(Platform.resolvedExecutable);
    return p.basename(directory).toLowerCase() == 'bin' &&
            p.basename(p.dirname(directory)).toLowerCase() == 'host'
        ? p.dirname(p.dirname(directory))
        : directory;
  }

  static String knownFolder(String guid) => using((arena) {
    final id = GUIDFromString(guid, allocator: arena);
    final output = arena<Pointer<Utf16>>();
    final result = SHGetKnownFolderPath(id, 0, 0, output);
    if (result < 0) {
      throw FileSystemException('Cannot resolve Windows known folder');
    }
    try {
      return output.value.toDartString();
    } finally {
      CoTaskMemFree(output.value);
    }
  });
}

Future<Directory> getApplicationSupportDirectory() async {
  final explicit =
      HostPaths.stateDirectory ?? Platform.environment['EXPERT_HOST_DATA_DIR'];
  if (explicit != null) {
    return Directory(p.normalize(p.absolute(explicit))).create(recursive: true);
  }
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Host data directory must be explicit on this platform',
    );
  }
  return Directory(
    p.join(
      HostPaths.knownFolder('{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}'),
      'com.wweiyi',
      'Expert Chat',
    ),
  ).create(recursive: true);
}

Future<Directory> getApplicationDocumentsDirectory() async {
  if (HostPaths.stateDirectory != null ||
      Platform.environment.containsKey('EXPERT_HOST_DATA_DIR')) {
    return Directory(
      p.join((await getApplicationSupportDirectory()).path, 'documents'),
    ).create(recursive: true);
  }
  if (!Platform.isWindows) {
    throw UnsupportedError('Host documents directory is unavailable');
  }
  return Directory(
    HostPaths.knownFolder('{FDD39AD0-238F-46AF-ADB4-6C85480369C7}'),
  );
}

Future<Directory> getTemporaryDirectory() async => Directory.systemTemp;
Future<Directory?> getExternalStorageDirectory() async => null;
Future<Directory?> getDownloadsDirectory() async => Platform.isWindows
    ? Directory(HostPaths.knownFolder('{374DE290-123F-4565-9164-39C4925E467B}'))
    : null;
