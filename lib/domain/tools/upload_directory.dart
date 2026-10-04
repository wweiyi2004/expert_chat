import 'dart:typed_data';

import 'upload_directory_models.dart';
import 'upload_directory_stub.dart'
    if (dart.library.io) 'upload_directory_io.dart'
    as platform;

export 'upload_directory_models.dart';

/// Lists only the directory selected by the user; file contents are read only
/// after the selection is confirmed and the regular ingestion limits apply.
class UploadDirectoryBrowser {
  const UploadDirectoryBrowser();

  bool get supported => platform.uploadDirectorySupported;

  Future<UploadDirectory?> restore() => platform.restoreUploadDirectory();

  Future<UploadDirectory?> choose() => platform.chooseUploadDirectory();

  Future<UploadDirectory> list({required String root, required String uri}) =>
      platform.listUploadDirectory(root: root, uri: uri);

  Future<Uint8List?> readBytes({
    required String root,
    required UploadDirectoryEntry entry,
  }) => platform.readUploadDirectoryFile(root: root, entry: entry);
}
