import 'dart:convert';

/// Keep binary artifacts out of text diffs and bound retained text snapshots.
/// The file host validates scope/existence and computes the content hash.
String? deliverySnapshotText(Map file, String path) {
  if (file['encoding'] != 'base64') return file['content'] as String;
  const binaryExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'ico',
    'bmp',
    'pdf',
    'doc',
    'docx',
    'ppt',
    'pptx',
    'xls',
    'xlsx',
    'zip',
    '7z',
    'gz',
    'tar',
    'exe',
    'dll',
    'mp3',
    'mp4',
    'wav',
    'woff',
    'woff2',
    'ttf',
    'db',
    'sqlite',
  };
  if (binaryExtensions.contains(path.split('.').last.toLowerCase())) {
    return null;
  }
  final bytes = base64Decode(file['content'] as String);
  if (bytes.length > 1024 * 1024 || bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}
