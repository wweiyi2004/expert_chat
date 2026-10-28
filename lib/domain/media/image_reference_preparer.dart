import 'dart:convert';
import 'dart:typed_data';

import '../../platform/foundation.dart' show compute;

import '../../data/models.dart';
import 'image_codec_util.dart';
import 'image_edit_reference.dart';

class ImageReferencePreparation {
  ImageReferencePreparation({
    List<ImageEditReference> references = const [],
    this.error,
    this.cancelled = false,
  }) : references = List.unmodifiable(references);
  final List<ImageEditReference> references;
  final String? error;
  final bool cancelled;
}

/// Prepares ordered references; saved-version replay preserves original bytes.
class ImageReferencePreparer {
  const ImageReferencePreparer({
    this.decode = decodeBase64,
    this.prepareImage = _prepareImage,
  });
  final Future<Uint8List> Function(String) decode;
  final Future<PreparedReferenceImage> Function(
    Uint8List bytes, {
    required String mimeType,
    required String name,
  })
  prepareImage;

  static Future<Uint8List> decodeBase64(String value) async =>
      value.length >= 256 * 1024
      ? await compute(base64Decode, value)
      : base64Decode(value);

  static Future<PreparedReferenceImage> _prepareImage(
    Uint8List bytes, {
    required String mimeType,
    required String name,
  }) => ImageCodecUtil.prepareReferenceImage(
    bytes,
    mimeType: mimeType,
    name: name,
  );

  Future<ImageReferencePreparation> prepare(
    List<Attachment> sources, {
    required bool preserveOriginalBytes,
    required bool Function() isActive,
  }) async {
    final references = <ImageEditReference>[];
    for (final source in sources) {
      if (!isActive()) return ImageReferencePreparation(cancelled: true);
      final encoded = source.imageBase64;
      if (encoded == null || encoded.isEmpty) {
        return ImageReferencePreparation(
          error: '参考图「${source.name}」缺少本地数据，请重新从相册/文件选择。',
        );
      }
      try {
        final raw = await decode(encoded);
        if (!isActive()) return ImageReferencePreparation(cancelled: true);
        if (preserveOriginalBytes) {
          references.add(
            ImageEditReference(
              bytes: raw,
              mimeType: source.mimeType,
              fileName: source.name,
            ),
          );
        } else {
          final prepared = await prepareImage(
            Uint8List.fromList(raw),
            mimeType: source.mimeType,
            name: source.name,
          );
          if (!isActive()) return ImageReferencePreparation(cancelled: true);
          references.add(
            ImageEditReference(
              bytes: prepared.bytes,
              mimeType: prepared.mimeType,
              fileName: prepared.name,
            ),
          );
        }
      } on FormatException {
        return ImageReferencePreparation(
          error: '参考图「${source.name}」数据无效，请重新选择图片。',
        );
      }
    }
    return ImageReferencePreparation(
      references: references,
      cancelled: !isActive(),
    );
  }
}
