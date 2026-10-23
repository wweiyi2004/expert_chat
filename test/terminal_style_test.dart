import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:expert_chat/features/workbench/runtime/terminal_style.dart';

void main() {
  testWidgets('PowerShell ANSI input remains readable on light and dark surfaces', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final font = File(r'C:\Windows\Fonts\consola.ttf');
      if (await font.exists()) {
        final loader = FontLoader('Consolas')
          ..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          );
        await loader.load();
      }
    });
    final terminal = Terminal()
      ..write(
        'PS E:\\project> \x1b[93mGet-ChildItem \x1b[90m-Path \x1b[36m"src"\x1b[0m\r\n'
        'PS E:\\project> \x1b[92m\$name\x1b[37m = \x1b[36m"Expert Chat"\x1b[0m\r\n'
        '\x1b[32m# PowerShell syntax highlighting\x1b[0m\r\n'
        'PS E:\\project> \x1b[93mWrite-Output \x1b[92m\$name\x1b[0m\r\n'
        'Expert Chat\r\n',
      );
    final boundaryKey = GlobalKey();
    for (final brightness in Brightness.values) {
      final colors = ColorScheme.fromSeed(
        seedColor: Colors.deepPurple,
        brightness: brightness,
      );
      final theme = workspaceTerminalTheme(colors);
      if (brightness == Brightness.light) {
        for (final ink in [
          theme.white,
          theme.brightWhite,
          theme.brightYellow,
          theme.brightGreen,
          theme.brightBlack,
          theme.cyan,
          theme.green,
        ]) {
          final a = ink.computeLuminance(),
              b = theme.background.computeLuminance();
          final contrast =
              (a > b ? a + .05 : b + .05) / (a > b ? b + .05 : a + .05);
          expect(contrast, greaterThanOrEqualTo(4.5));
        }
      }
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: colors.surface,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: TerminalView(
                  terminal,
                  theme: theme,
                  textStyle: const TerminalStyle(
                    fontSize: 16,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        await Directory('output').create(recursive: true);
        await File(
          'output/powershell-colors-${brightness.name}.png',
        ).writeAsBytes(bytes);
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
