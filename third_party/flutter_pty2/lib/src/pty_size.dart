final class PtySize {
  const PtySize({
    required this.columns,
    required this.rows,
    this.pixelWidth = 0,
    this.pixelHeight = 0,
  });

  final int columns;
  final int rows;
  final int pixelWidth;
  final int pixelHeight;

  void validate() {
    if (columns <= 0 || columns > 0x7fff) {
      throw ArgumentError.value(
        columns,
        'columns',
        'must be between 1 and 32767',
      );
    }
    if (rows <= 0 || rows > 0x7fff) {
      throw ArgumentError.value(
        rows,
        'rows',
        'must be between 1 and 32767',
      );
    }
    if (pixelWidth < 0 || pixelWidth > 0xffff) {
      throw ArgumentError.value(
        pixelWidth,
        'pixelWidth',
        'must be between 0 and 65535',
      );
    }
    if (pixelHeight < 0 || pixelHeight > 0xffff) {
      throw ArgumentError.value(
        pixelHeight,
        'pixelHeight',
        'must be between 0 and 65535',
      );
    }
  }
}
