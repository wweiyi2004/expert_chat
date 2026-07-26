import 'dart:convert';
import 'dart:typed_data';

import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/attachment_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('small base64 images render on the first frame', (tester) async {
    final b64 = base64Encode(Uint8List.fromList(List.filled(64, 7)));

    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentImage(
          attachment: Attachment(
            name: 'small.png',
            mimeType: 'image/png',
            imageBase64: b64,
          ),
        ),
      ),
    );

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('large base64 images decode off-frame with a progress state', (
    tester,
  ) async {
    // ~400K base64 chars — above the isolate-decode threshold.
    final big = base64Encode(
      Uint8List.fromList(List.generate(300 * 1024, (i) => i % 251)),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentImage(
            attachment: Attachment(
              name: 'big.png',
              mimeType: 'image/png',
              imageBase64: big,
            ),
          ),
        ),
      );

      // First frame: the widget must not have blocked on a synchronous
      // multi-megabyte decode; it shows progress instead.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(Image), findsNothing);

      // Wait for the background isolate to finish.
      var waited = 0;
      while (waited < 5000) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        waited += 50;
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
    });
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
