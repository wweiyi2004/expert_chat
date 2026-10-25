import 'dart:io';
import 'dart:ui' as ui;
import 'package:expert_chat/core/application_surface.dart';
import 'package:expert_chat/core/line_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('close respects a guarded root editor', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ApplicationSurface(
          title: '编辑器',
          onClose: () {
            closed = true;
          },
          child: const PopScope(
            canPop: false,
            child: Scaffold(body: Text('未保存的根编辑器')),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('关闭窗口'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    expect(await ApplicationSurface.closeActive(), isFalse);
    expect(closed, isFalse);
  });
  for (final width in [360.0, 390.0, 1280.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'internal destination $width dark=$dark keeps draft and editor bounds',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final draft = TextEditingController(text: '保留的对话草稿');
          addTearDown(draft.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? ThemeData.dark() : ThemeData.light(),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Column(
                    children: [
                      TextField(controller: draft),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          applicationSurfaceRoute<void>(
                            context,
                            (context) => Scaffold(
                              body: ListView(
                                children: [
                                  const Text('配置内容'),
                                  TextButton(
                                    onPressed: () => Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) => const Scaffold(
                                          body: Center(child: Text('子编辑器')),
                                        ),
                                      ),
                                    ),
                                    child: const Text('打开子编辑器'),
                                  ),
                                  for (var i = 0; i < 30; i++)
                                    ListTile(title: Text('滚动配置 $i')),
                                  const Row(
                                    children: [
                                      LineIcon(Icons.search),
                                      LineIcon(Icons.folder_outlined),
                                      LineIcon(Icons.edit_square),
                                      LineIcon(Icons.more_vert),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            title: '设置',
                          ),
                        ),
                        child: const Text('打开设置'),
                      ),
                    ],
                  ),
                ),
              ),
              builder: (context, child) => RepaintBoundary(
                key: const ValueKey('surface-render'),
                child: child!,
              ),
            ),
          );
          await tester.tap(find.text('打开设置'));
          await tester.pumpAndSettle();
          if (width >= 840) {
            final rect = tester.getRect(
              find.byKey(const ValueKey('application-surface')),
            );
            expect(rect.left, greaterThan(0));
            expect(rect.right, lessThan(width));
            expect(rect.top, greaterThan(0));
            expect(rect.bottom, lessThan(900));
            await tester.tap(find.text('打开子编辑器'));
            await tester.pumpAndSettle();
            final editor = tester.getRect(find.text('子编辑器'));
            expect(rect.contains(editor.center), isTrue);
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('surface-render')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(
                'output/refinement-review/shell',
              ).create(recursive: true);
              await File(
                'output/refinement-review/shell/surface-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
            await tester.tap(find.byTooltip('关闭窗口'));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('application-surface')),
              findsNothing,
            );
          } else {
            expect(
              find.byKey(const ValueKey('application-surface')),
              findsNothing,
            );
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
          }
          expect(draft.text, '保留的对话草稿');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('close respects a child editor that refuses to pop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ApplicationSurface(
          title: '设置',
          onClose: () {
            closed = true;
          },
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const PopScope(
                    canPop: false,
                    child: Scaffold(body: Text('未保存的编辑器')),
                  ),
                ),
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭窗口'));
    await tester.pumpAndSettle();
    expect(closed, isFalse);
    expect(find.text('未保存的编辑器'), findsOneWidget);
  });
}
