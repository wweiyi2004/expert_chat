import 'dart:io';
import 'dart:ui' as ui;

import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/features/settings/widgets/mcp_settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _path =
    r'C:\Users\username\AppData\Local\Programs\very-long-program-directory\mcp-driver.exe';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final width in [360.0, 390.0, 1280.0, 1440.0]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.24]) {
        testWidgets('MCP form $width dark=$dark scale=$scale', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 1000));
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          addTearDown(tester.view.resetViewInsets);
          dynamic saved;
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(
                  key: const ValueKey('dialog-capture'),
                  child: child!,
                ),
              ),
              home: RepaintBoundary(
                key: const ValueKey('capture'),
                child: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () async {
                        saved = await showDialog<dynamic>(
                          context: context,
                          builder: (_) => const CustomMcpEditorDialog(
                            name: '本地工具',
                            url: '',
                            token: '',
                            localProcess: McpProcessConfig(
                              command: _path,
                              arguments: ['mcp', '--direct'],
                              workingDirectory: r'C:\work',
                            ),
                          ),
                        );
                      },
                      child: const Text('edit'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('edit'));
          await tester.pumpAndSettle();
          final command = field('程序路径');
          final arguments = field('参数（每行一个）');
          final directory = field('工作目录（可选）');
          final commandRect = tester.getRect(command);
          final argsRect = tester.getRect(arguments);
          final directoryRect = tester.getRect(directory);
          expect(commandRect.height, greaterThanOrEqualTo(54));
          expect(argsRect.top - commandRect.bottom, greaterThanOrEqualTo(16));
          expect(directoryRect.top - argsRect.bottom, greaterThanOrEqualTo(16));
          expect(
            tester.widget<TextField>(arguments).decoration!.alignLabelWithHint,
            isTrue,
          );
          final picker = find.byTooltip('选择 MCP 程序');
          expect(tester.getRect(picker).width, greaterThanOrEqualTo(40));
          expect(commandRect.contains(tester.getRect(picker).center), isTrue);
          await tester.ensureVisible(arguments);
          await tester.enterText(arguments, 'mcp\n--direct\n--port\n1234');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('SETTINGS_FORM_EVIDENCE')) {
            await tester.runAsync(() async {
              final boundary = tester.renderObject<RenderRepaintBoundary>(
                find.byKey(const ValueKey('dialog-capture')),
              );
              final image = await boundary.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'output/settings-comfort-review/mcp-${width.toInt()}-${dark ? 'dark' : 'light'}-$scale.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
            });
          }
          if (width < 600) {
            tester.view.viewInsets = const FakeViewPadding(bottom: 280);
            await tester.pumpAndSettle();
            await tester.ensureVisible(directory);
            await tester.enterText(directory, r'C:\work');
            await tester.pumpAndSettle();
            expect(
              tester.getRect(find.text('保存')).bottom,
              lessThanOrEqualTo(720),
            );
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(saved.localProcess.command, _path);
          expect(saved.localProcess.arguments, [
            'mcp',
            '--direct',
            '--port',
            '1234',
          ]);
          expect(saved.localProcess.workingDirectory, r'C:\work');
          expect(saved.name, '本地工具');
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
