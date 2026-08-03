/// One source image for `/images/edits` (图生图 / multi-ref GPT Image).
class ImageEditReference {
  const ImageEditReference({
    required this.bytes,
    this.mimeType = 'image/png',
    this.fileName = 'reference.png',
  });

  final List<int> bytes;
  final String mimeType;
  final String fileName;
}
