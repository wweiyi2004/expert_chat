enum LibraryItemKind { image, file }

class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.mimeType,
    required this.sizeBytes,
    required this.relativePath,
    required this.sha256,
    required this.createdAt,
    required this.lastUsedAt,
  });

  final String id;
  final String name;
  final LibraryItemKind kind;
  final String mimeType;
  final int sizeBytes;
  final String relativePath;
  final String sha256;
  final DateTime createdAt;
  final DateTime lastUsedAt;

  bool get isImage => kind == LibraryItemKind.image;
}

/// Display name for a generated image in the 素材 library.
///
/// Kept short so it is readable in the picker. The bytes on disk use a
/// UUID file name and never embed the prompt.
///
/// Example: `生图-20260901-153012-华科图书.png`
String libraryGeneratedImageName({
  String prompt = '',
  String mimeType = 'image/png',
  DateTime? at,
}) {
  final time = at ?? DateTime.now();
  final stamp =
      '${time.year.toString().padLeft(4, '0')}'
      '${time.month.toString().padLeft(2, '0')}'
      '${time.day.toString().padLeft(2, '0')}-'
      '${time.hour.toString().padLeft(2, '0')}'
      '${time.minute.toString().padLeft(2, '0')}'
      '${time.second.toString().padLeft(2, '0')}';
  final ext = libraryFileExtension(mimeType);
  final slug = libraryImageSlug(prompt);
  return slug.isEmpty ? '生图-$stamp.$ext' : '生图-$stamp-$slug.$ext';
}

/// At most 8 letters/CJK with no spaces or punctuation.
String libraryImageSlug(String prompt) {
  final cleaned = prompt
      .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t.*]+'), '')
      .replaceAll(RegExp(r'\s+'), '');
  if (cleaned.isEmpty) return '';
  return cleaned.length <= 8 ? cleaned : cleaned.substring(0, 8);
}

String libraryFileExtension(String mimeType) =>
    switch (mimeType.toLowerCase()) {
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/png' => 'png',
      _ => 'bin',
    };
