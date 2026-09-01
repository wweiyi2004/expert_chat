import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:path_provider/path_provider.dart';

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
    final folder = await _ensureFolder(image);
    final ext = _safeExtension(fileName);
    final file = File('${folder.path}${Platform.pathSeparator}$id.$ext');
    await file.writeAsBytes(bytes, flush: true);
    return '${image ? 'images' : 'files'}${Platform.pathSeparator}$id.$ext';
  }

  Future<Uint8List?> readBytes(String relativePath) async {
    final root = await rootPath;
    final file = File('$root${Platform.pathSeparator}$relativePath');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<void> delete(String relativePath) async {
    final root = await rootPath;
    final file = File('$root${Platform.pathSeparator}$relativePath');
    if (await file.exists()) {
      await file.delete();
    }
  }
}

String _safeExtension(String fileName) {
  final i = fileName.lastIndexOf('.');
  if (i < 0 || i == fileName.length - 1) return 'bin';
  final ext = fileName.substring(i + 1).toLowerCase();
  if (ext.length > 8 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return 'bin';
  return ext;
}
