import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/core/prototype_widgets.dart';

void main() {
  testWidgets('small phone visual keeps a transparent 44 target', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: PrototypeButton(
              label: '批准',
              small: true,
              onPressed: () => calls++,
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(PrototypeButton));
    expect(rect.height, 44);
    expect(rect.width, greaterThanOrEqualTo(44));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 1));
    await tester.pump();
    expect(calls, 1);
  });
  testWidgets(
    'keyboard activates enabled controls and focus outline is visible',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Column(
              children: [
                const PrototypeButton(label: '禁用', onPressed: null),
                PrototypeButton(label: '启用', onPressed: () => calls++),
              ],
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final ring = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('prototype-focus-outline')),
      );
      expect((ring.decoration as BoxDecoration).border!.top.width, 2);
      expect(
        (ring.decoration as BoxDecoration).border!.top.color,
        AppTheme.light().colorScheme.primary,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(calls, 2);
      await tester.tap(find.text('禁用'));
      await tester.pump();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'long scaled button label is constrained and full text remains discoverable',
    (tester) async {
      const label = '在这个特别长的执行位置中打开已经保存的完整项目目录和所有交付文件';
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 700),
                textScaler: TextScaler.linear(1.24),
              ),
              child: SizedBox(
                width: 260,
                child: PrototypeButton(
                  label: label,
                  tooltip: label,
                  onPressed: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip(label), findsOneWidget);
      expect(
        tester.getSize(find.byType(PrototypeButton)).width,
        lessThanOrEqualTo(260),
      );
    },
  );
  testWidgets(
    'tabs occupy bounded width and expanded buttons actually paint half widths',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: Column(
                children: [
                  PrototypeTabStrip<int>(
                    tabs: const [
                      PrototypeTab(value: 0, label: '改动'),
                      PrototypeTab(value: 1, label: '运行'),
                    ],
                    value: 0,
                    onChanged: (_) {},
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: PrototypeButton(
                          label: '批准',
                          expand: true,
                          small: true,
                          variant: PrototypeButtonVariant.primary,
                          onPressed: () {},
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: PrototypeButton(
                          label: '拒绝',
                          expand: true,
                          small: true,
                          onPressed: () {},
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(PrototypeTabStrip<int>)).width, 320);
      final painted = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                AppTheme.light().colorScheme.primary,
      );
      expect(tester.getSize(painted).width, 156);
      expect(tester.takeException(), isNull);
    },
  );
}
