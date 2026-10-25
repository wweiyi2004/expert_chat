import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [360.0, 1440.0]) {
    testWidgets(
      'toast floats at lower right, replaces, closes and expires $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  ctx = context;
                  return const Center(child: Text('页面内容'));
                },
              ),
            ),
          ),
        );
        final original = tester.getRect(find.text('页面内容'));
        final host = AppToastMessenger.of(ctx);
        host.showSnackBar(const SnackBar(content: Text('已复制')));
        await tester.pump();
        final box = tester.getRect(find.byKey(const ValueKey('app-toast')));
        expect(box.right, width - 16);
        expect(box.bottom, lessThanOrEqualTo(820));
        expect(box.bottom, greaterThan(650));
        expect(box.left, greaterThanOrEqualTo(16));
        expect(tester.getRect(find.text('页面内容')), original);
        host.showSnackBar(const SnackBar(content: Text('已保存')));
        await tester.pump();
        expect(find.text('已复制'), findsNothing);
        expect(find.byKey(const ValueKey('app-toast')), findsOneWidget);
        await tester.tap(find.byTooltip('关闭提示'));
        await tester.pump();
        expect(find.text('已保存'), findsNothing);
        final auto = host.showSnackBar(const SnackBar(content: Text('完成')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1900));
        expect(find.text('完成'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 101));
        expect(find.text('完成'), findsNothing);
        expect(await auto.closed, SnackBarClosedReason.timeout);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'toast preserves undo callback and persistent download feedback',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      var undone = false;
      final host = AppToastMessenger.of(ctx);
      host.showSnackBar(
        SnackBar(
          content: const Text('已归档'),
          action: SnackBarAction(label: '撤销', onPressed: () => undone = true),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(undone, isTrue);
      host.showSnackBar(
        const SnackBar(content: Text('下载中'), duration: Duration(days: 1)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('下载中'), findsOneWidget);
      host.clearSnackBars();
      await tester.pump();
      expect(find.text('下载中'), findsNothing);
    },
  );
  testWidgets('toast visual matrix across desktop phone and themes', (
    tester,
  ) async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    final key = GlobalKey();
    late BuildContext ctx;
    for (final width in [360.0, 390.0, 1280.0, 1440.0]) {
      for (final dark in [false, true]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    ctx = context;
                    return const Center(child: Text('当前对话保持原位'));
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final host = AppToastMessenger.of(ctx);
        host.showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = File(
            'output/refinement-review/toasts/toast-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
          );
          await path.parent.create(recursive: true);
          await path.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        host.clearSnackBars();
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }
    tester.view.reset();
  });
}
