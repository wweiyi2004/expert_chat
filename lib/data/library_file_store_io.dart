import 'dart:io';
import 'dart:typed_data';

import '../platform/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import '../platform/paths.dart';
import 'library_paths.dart';

/// App-owned library folder: `ExpertChat/素材/{images|files}/`.
class LibraryFileStore {
  LibraryFileStore({this.rootOverride});

  /// Tests inject a temp directory.
  final String? rootOverride;

  Future<String> get rootPath async {
    final injected = rootOverride;
    if (injected != null) return injected;
    Directory base;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        base =
            await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      } catch (_) {
        base = await getApplicationDocumentsDirectory();
      }
    } else {
      base = await getApplicationDocumentsDirectory();
    }
    return '${base.path}${Platform.pathSeparator}ExpertChat${Platform.pathSeparator}素材';
  }

  Future<Directory> _ensureFolder(bool image) async {
    final root = await rootPath;
    final folder = Directory(
      '$root${Platform.pathSeparator}${image ? 'images' : 'files'}',
    );
    await folder.create(recursive: true);
    return folder;
  }

  Future<String> writeBytes({
    required String id,
    required String fileName,
    required bool image,
    required Uint8List bytes,
  }) async {
    final relative = libraryRelativePath(id, fileName, image);
    await _ensureFolder(image);
    final file = File('${await rootPath}/$relative');
    await file.writeAsBytes(bytes, flush: true);
    return relative;
  }

  Future<Uint8List?> readBytes(String relativePath) async {
    final root = await rootPath;
    final file = File('$root/${validateLibraryPath(relativePath)}');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> delete(String relativePath) async {
    final root = await rootPath;
    final file = File('$root/${validateLibraryPath(relativePath)}');
    if (await file.exists()) {
      await file.delete();
    }
  }
}
