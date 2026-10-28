import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import '../../platform/media_worker.dart';

class ImageCodecUtil {
  const ImageCodecUtil._();
  static const maxEditSide = 1536;
  static Future<Uint8List> downscaleForEdit(
    Uint8List bytes, {
    int maxSide = maxEditSide,
  }) async {
    if (bytes.isEmpty || maxSide <= 0) return bytes;
    final result = await Isolate.run(
      () => runMediaWorker({
        'op': 'image_resize',
        'data': base64Encode(bytes),
        'max_side': maxSide,
      }),
    );
    return result['changed'] == true
        ? base64Decode(result['data'] as String)
        : bytes;
  }

  static Future<PreparedReferenceImage> prepareReferenceImage(
    Uint8List bytes, {
    String mimeType = 'image/png',
    String name = 'reference.png',
    int maxSide = maxEditSide,
  }) async {
    final resized = await downscaleForEdit(bytes, maxSide: maxSide);
    if (identical(resized, bytes)) {
      return PreparedReferenceImage(
        bytes: bytes,
        mimeType: mimeType,
        name: name,
      );
    }
    final base = name.replaceAll(RegExp(r'\.[^.]+$'), '');
    return PreparedReferenceImage(
      bytes: resized,
      mimeType: 'image/png',
      name: '${base.isEmpty ? 'reference' : base}.png',
    );
  }
}

class PreparedReferenceImage {
  const PreparedReferenceImage({
    required this.bytes,
    required this.mimeType,
    required this.name,
  });
  final Uint8List bytes;
  final String mimeType, name;
}
