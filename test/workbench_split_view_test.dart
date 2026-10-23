import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/features/workbench/workbench_split_view.dart';

void main() {
  for (final width in [500.0, 900.0]) {
    testWidgets('workbench divider resizes panes at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WorkbenchSplitView(
              first: ColoredBox(key: ValueKey('first'), color: Colors.red),
              second: ColoredBox(key: ValueKey('second'), color: Colors.blue),
            ),
          ),
        ),
      );
      final before = tester.getSize(find.byKey(const ValueKey('first')));
      await tester.drag(
        find.bySemanticsLabel('拖动调整两个面板大小'),
        width >= 680 ? const Offset(100, 0) : const Offset(0, 100),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final after = tester.getSize(find.byKey(const ValueKey('first')));
      expect(
        width >= 680 ? after.width : after.height,
        greaterThan(width >= 680 ? before.width : before.height),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
