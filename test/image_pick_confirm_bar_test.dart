import 'dart:convert';

import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/image_pick_confirm_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ImagePickConfirmBar toggles selection and confirms', (
    tester,
  ) async {
    // 1x1 PNG
    const tinyPngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    final candidates = [
      PendingImagePick(
        attachment: Attachment(
          name: 'a.png',
          mimeType: 'image/png',
          sizeBytes: 68,
          imageBase64: tinyPngBase64,
        ),
        selected: true,
      ),
      PendingImagePick(
        attachment: Attachment(
          name: 'b.png',
          mimeType: 'image/png',
          sizeBytes: 68,
          imageBase64: tinyPngBase64,
        ),
        selected: true,
      ),
    ];
    var confirmed = false;
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return ImagePickConfirmBar(
                candidates: candidates,
                maxSelectable: 2,
                onChanged: () => setState(() {}),
                onCancel: () => cancelled = true,
                onConfirm: () => confirmed = true,
              );
            },
          ),
        ),
      ),
    );

    expect(find.textContaining('已选 2'), findsOneWidget);
    expect(find.text('添加 (2)'), findsOneWidget);

    // Tap second thumb to deselect.
    await tester.tap(find.byType(InkWell).at(1));
    await tester.pump();
    expect(find.textContaining('已选 1'), findsOneWidget);

    await tester.tap(find.text('添加 (1)'));
    expect(confirmed, isTrue);

    await tester.tap(find.text('取消'));
    expect(cancelled, isTrue);

    // Sanity: base64 decodes
    expect(base64Decode(tinyPngBase64), isNotEmpty);
  });

  testWidgets('single-slot mode behaves like radio', (tester) async {
    const tinyPngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    final candidates = [
      PendingImagePick(
        attachment: Attachment(
          name: 'a.png',
          mimeType: 'image/png',
          imageBase64: tinyPngBase64,
        ),
        selected: true,
      ),
      PendingImagePick(
        attachment: Attachment(
          name: 'b.png',
          mimeType: 'image/png',
          imageBase64: tinyPngBase64,
        ),
        selected: false,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return ImagePickConfirmBar(
                candidates: candidates,
                maxSelectable: 1,
                onChanged: () => setState(() {}),
                onCancel: () {},
                onConfirm: () {},
              );
            },
          ),
        ),
      ),
    );

    expect(find.textContaining('最多 1 张'), findsOneWidget);
    await tester.tap(find.byType(InkWell).at(1));
    await tester.pump();
    expect(candidates[0].selected, isFalse);
    expect(candidates[1].selected, isTrue);
  });
}
