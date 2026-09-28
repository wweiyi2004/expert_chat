import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:expert_chat/domain/media/image_codec_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'reference image scales once to target dimensions and preserves small originals',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(
          recorder,
        ).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final source = await picture.toImage(96, 48);
        final data = (await source.toByteData(format: ui.ImageByteFormat.png))!;
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        source.dispose();
        picture.dispose();
        final unchanged = await ImageCodecUtil.downscaleForEdit(
          bytes,
          maxSide: 100,
        );
        expect(unchanged, same(bytes));
        final prepared = await ImageCodecUtil.prepareReferenceImage(
          bytes,
          name: 'photo.jpg',
          mimeType: 'image/jpeg',
          maxSide: 32,
        );
        expect(prepared.name, 'photo.png');
        expect(prepared.mimeType, 'image/png');
        final buffer = await ui.ImmutableBuffer.fromUint8List(prepared.bytes);
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        expect(descriptor.width, 32);
        expect(descriptor.height, 16);
        descriptor.dispose();
        buffer.dispose();
        final invalid = Uint8List.fromList([1, 2, 3]);
        expect(await ImageCodecUtil.downscaleForEdit(invalid), same(invalid));
      });
    },
  );
}
