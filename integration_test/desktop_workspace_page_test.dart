import 'dart:io';
import 'dart:ui' as ui;
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:expert_chat/features/workspaces/desktop_workspaces_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'packaged Windows workspace service works from its management page',
    (tester) async {
      final sandbox = await Directory.systemTemp.createTemp(
        'expert-workspace-native-',
      );
      final project = await Directory(p.join(sandbox.path, '示例工程')).create();
      final host = CliDesktopWorkspaceHost(
        dataDirectory: p.join(sandbox.path, 'state'),
      );
      final imageKey = GlobalKey();
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [desktopWorkspaceHostProvider.overrideWithValue(host)],
            child: RepaintBoundary(
              key: imageKey,
              child: MaterialApp(
                home: DesktopWorkspacesPage(
                  pickDirectory: () async => project.path,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('还没有电脑工作区'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '添加工作区'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择文件夹'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('workspace-name')),
          '桌面界面验证',
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.text('桌面界面验证'), findsOneWidget);
        final saved = (await host.list()).single;
        expect(saved.name, '桌面界面验证');
        await tester.tap(find.byTooltip('编辑目录权限'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace-access')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('读写').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(
          (await host.list()).single.scopes.single.access.wireValue,
          'read-write',
        );
        expect(tester.takeException(), isNull);
        final boundary =
            imageKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Platform.environment['EXPERT_WORKSPACE_SCREENSHOT'];
        if (output != null) {
          await File(output).writeAsBytes(png!.buffer.asUint8List());
        }
        image.dispose();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        final parent = await sandbox.parent.resolveSymbolicLinks();
        if (parent != await Directory.systemTemp.resolveSymbolicLinks() ||
            !p.basename(sandbox.path).startsWith('expert-workspace-native-')) {
          throw StateError('Unexpected test directory');
        }
        await sandbox.delete(recursive: true);
      }
    },
  );
}
