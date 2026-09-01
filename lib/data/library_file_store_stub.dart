import 'dart:typed_data';

/// Web / stub: keep library bytes in memory for the process lifetime.
class LibraryFileStore {
  LibraryFileStore({this.rootOverride});

  /// Unused on web; accepted so tests can inject a path on IO.
  final String? rootOverride;

  final Map<String, Uint8List> _files = {};

  Future<String> get rootPath async => rootOverride ?? 'memory://library';

  Future<String> writeBytes({
    required String id,
    required String fileName,
    required bool image,
    required Uint8List bytes,
  }) async {
    final folder = image ? 'images' : 'files';
    final i = fileName.lastIndexOf('.');
    final ext = (i > 0 && i < fileName.length - 1)
        ? fileName.substring(i + 1).toLowerCase()
        : 'bin';
    final relative = '$folder/$id.$ext';
    _files[relative] = Uint8List.fromList(bytes);
    return relative;
  }

  Future<Uint8List?> readBytes(String relativePath) async =>
      _files[relativePath];

  Future<void> delete(String relativePath) async {
    _files.remove(relativePath);
  }
}
