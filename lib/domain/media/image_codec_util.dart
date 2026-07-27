import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decode / downscale helpers for chat attachments and img2img uploads.
///
/// Full-resolution phone photos (12MP+) must not be decoded at native size in
/// list tiles - that is a common source of OOM / native crashes when several
/// images appear in one conversation.
class ImageCodecUtil {
  const ImageCodecUtil._();

  /// Longest edge for reference images sent to `/images/edits`.
  static const int maxEditSide = 1536;

  /// Re-encode [bytes] so the long edge is ≤ [maxSide].
  ///
  /// Returns the original bytes when already small enough or when decoding
  /// fails (caller may still try the original with the API). All `ui.Codec` /
  /// `ui.Image` handles are disposed - the previous implementation leaked both
  /// and accumulated native-decoder memory across img2img turns.
  ///
  /// `instantiateImageCodec` cannot run on a background isolate (no engine
  /// binding), so this runs on the UI isolate. Callers keep the base64 decode
  /// on `compute()`; only the resize (which is target-bound and never
  /// materialises the full-size pixel buffer) happens here.
  static Future<Uint8List> downscaleForEdit(
    Uint8List bytes, {
    int maxSide = maxEditSide,
  }) async {
    if (bytes.isEmpty || maxSide <= 0) return bytes;
    ui.Codec? probe;
    ui.Image? probeImage;
    try {
      // One probe decode to learn the dimensions.
      probe = await ui.instantiateImageCodec(bytes);
      final probeFrame = await probe.getNextFrame();
      probeImage = probeFrame.image;
      final w = probeImage.width;
      final h = probeImage.height;
      if (w <= 0 || h <= 0) return bytes;
      if (w <= maxSide && h <= maxSide) return bytes;

      final targetW =
          w >= h ? maxSide : ((w * maxSide) / h).round().clamp(1, maxSide);
      final targetH =
          h > w ? maxSide : ((h * maxSide) / w).round().clamp(1, maxSide);

      // Release the full-size probe before allocating the downscaled frame.
      probeImage.dispose();
      probeImage = null;
      probe.dispose();
      probe = null;

      // targetWidth/targetHeight make Skia downsample while decoding, so the
      // full-size pixel buffer is never materialised - this is what prevents
      // the native stack overflow seen on Windows with large phone photos.
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetW,
        targetHeight: targetH,
      );
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          final bd = await image.toByteData(format: ui.ImageByteFormat.png);
          if (bd == null) return bytes;
          // Respect the view window: asUint8List() with no arguments would
          // hand back the whole backing store, not just this ByteData.
          return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        } finally {
          image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return bytes;
    } finally {
      probeImage?.dispose();
      probe?.dispose();
    }
  }

  /// Downscale (if needed) and report the matching mime type / file name.
  ///
  /// When no resize occurs the original [mimeType] / [name] are preserved; a
  /// resized image is re-encoded as PNG, so the name is rewritten to `.png`.
  /// Shared by the attachment picker (pre-scale at pick time, so the stored
  /// base64 is already small) and the img2img send path (fallback for
  /// references that did not come through the picker, e.g. old DB rows).
  static Future<PreparedReferenceImage> prepareReferenceImage(
    Uint8List bytes, {
    String mimeType = 'image/png',
    String name = 'reference.png',
    int maxSide = maxEditSide,
  }) async {
    final scaled = await downscaleForEdit(bytes, maxSide: maxSide);
    if (identical(scaled, bytes)) {
      return PreparedReferenceImage(
        bytes: scaled,
        mimeType: mimeType,
        name: name,
      );
    }
    final base = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    return PreparedReferenceImage(
      bytes: scaled,
      mimeType: 'image/png',
      name: '${base.isEmpty ? 'reference' : base}.png',
    );
  }
}

/// Outcome of [ImageCodecUtil.prepareReferenceImage]: the (possibly resized)
/// bytes plus the mime type / file name that matches them.
class PreparedReferenceImage {
  const PreparedReferenceImage({
    required this.bytes,
    required this.mimeType,
    required this.name,
  });

  final Uint8List bytes;
  final String mimeType;
  final String name;
}
