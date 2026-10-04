import 'package:path/path.dart' as p;

class UploadDirectoryEntry {
  const UploadDirectoryEntry({
    required this.uri,
    required this.name,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAt,
    this.mimeType = '',
  });

  final String uri;
  final String name;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime modifiedAt;
  final String mimeType;

  String get extension {
    final suffix = p.extension(name).replaceFirst('.', '').toLowerCase();
    if (suffix.isNotEmpty) return suffix;
    return switch (mimeType.toLowerCase()) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'application/pdf' => 'pdf',
      'text/plain' => 'txt',
      'text/markdown' => 'md',
      'text/csv' => 'csv',
      'application/json' => 'json',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document' =>
        'docx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' =>
        'xlsx',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation' =>
        'pptx',
      _ => '',
    };
  }
}

class UploadDirectory {
  const UploadDirectory({
    required this.root,
    required this.uri,
    required this.name,
    required this.entries,
  });

  final String root;
  final String uri;
  final String name;
  final List<UploadDirectoryEntry> entries;
}

List<UploadDirectoryEntry> sortUploadDirectoryEntries(
  Iterable<UploadDirectoryEntry> entries,
) => entries.toList()
  ..sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    final recent = b.modifiedAt.compareTo(a.modifiedAt);
    return recent != 0
        ? recent
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
