/// A library path is never a caller-supplied absolute path. Use portable '/'
/// separators in backups and validate again before disk access.
String libraryRelativePath(String id, String fileName, bool image) {
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
    throw const FormatException('素材 ID 不合法');
  }
  final extension = fileName.split('.').last.toLowerCase();
  final ext =
      fileName.contains('.') && RegExp(r'^[a-z0-9]{1,8}$').hasMatch(extension)
      ? extension
      : 'bin';
  return '${image ? 'images' : 'files'}/$id.$ext';
}

String validateLibraryPath(String path) {
  final portable = path.replaceAll('\\', '/');
  if (!RegExp(
    r'^(images|files)/[a-zA-Z0-9_-]+\.[a-z0-9]{1,8}$',
  ).hasMatch(portable)) {
    throw const FormatException('素材路径不合法');
  }
  return portable;
}
