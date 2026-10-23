import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/data/mcp_process_config.dart';
import 'package:expert_chat/features/workspaces/desktop_workspaces_page.dart';
import 'package:expert_chat/features/shell/tools_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryHost implements DesktopWorkspaceHost {
  final workspaces = <DesktopWorkspace>[];
  bool failSave = false;
  int writes = 0;
  @override
  bool get supported => true;
  @override
  Future<DesktopWorkspace> defaultWorkspace() async =>
      workspaces.where((w) => w.id == defaultDesktopWorkspaceId).firstOrNull ??
      await add(
        id: defaultDesktopWorkspaceId,
        name: '默认工作区',
        path: 'E:/App/desktop-workspaces/default',
        access: WorkspaceAccess.readWrite,
      );
  @override
  Future<McpProcessConfig> processFor(String workspaceId) async =>
      throw UnimplementedError('Widget fixture has no executable');
  @override
  Future<List<DesktopWorkspace>> list() async => List.of(workspaces);
  @override
  Future<DesktopWorkspace> add({
    required String id,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async {
    if (failSave) throw const WorkspaceHostException('目录不可访问');
    writes++;
    final workspace = DesktopWorkspace(
      id: id,
      name: name,
      root: path,
      scopes: [WorkspaceScope(name: 'root', path: path, access: access)],
    );
    workspaces.add(workspace);
    return workspace;
  }

  @override
  Future<DesktopWorkspace> setScope({
    required String workspace,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async {
    if (failSave) throw const WorkspaceHostException('目录不可访问');
    writes++;
    final index = workspaces.indexWhere((w) => w.id == workspace);
    final old = workspaces[index];
    return workspaces[index] = DesktopWorkspace(
      id: old.id,
      name: old.name,
      root: old.root,
      scopes: [
        for (final s in old.scopes)
          if (s.name != name) s,
        WorkspaceScope(name: name, path: path, access: access),
      ],
    );
  }

  @override
  Future<DesktopWorkspace> removeScope(String workspace, String name) async {
    final index = workspaces.indexWhere((w) => w.id == workspace);
    final old = workspaces[index];
    return workspaces[index] = DesktopWorkspace(
      id: old.id,
      name: old.name,
      root: old.root,
      scopes: old.scopes.where((s) => s.name != name).toList(),
    );
  }

  @override
  Future<void> remove(String workspace) async =>
      workspaces.removeWhere((w) => w.id == workspace);
}

class PageSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState();
}

Future<void> showPage(WidgetTester tester, MemoryHost host) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [desktopWorkspaceHostProvider.overrideWithValue(host)],
      child: MaterialApp(
        home: DesktopWorkspacesPage(pickDirectory: () async => 'E:/项目/demo'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop tools entry opens workspace management and returns', (
    tester,
  ) async {
    final host = MemoryHost();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopWorkspaceHostProvider.overrideWithValue(host),
          settingsControllerProvider.overrideWith(PageSettings.new),
        ],
        child: const MaterialApp(home: ToolsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('电脑工作区'));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWorkspacesPage), findsOneWidget);
    expect(find.text('还没有电脑工作区'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(DesktopWorkspacesPage), findsNothing);
    expect(find.text('工具'), findsOneWidget);
  });
  testWidgets(
    'add defaults to read-only, edit root permission, remove registration',
    (tester) async {
      final host = MemoryHost();
      await showPage(tester, host);
      expect(find.text('还没有电脑工作区'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '添加工作区'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件夹'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('workspace-name')),
        '测试工作区',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        host.workspaces.single.scopes.single.access,
        WorkspaceAccess.readOnly,
      );
      expect(find.text('测试工作区'), findsOneWidget);
      await tester.tap(find.byTooltip('编辑目录权限'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-access')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('读写').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        host.workspaces.single.scopes.single.access,
        WorkspaceAccess.readWrite,
      );
      await tester.ensureVisible(find.text('移除工作区'));
      await tester.tap(find.text('移除工作区'));
      await tester.pumpAndSettle();
      expect(find.textContaining('不删除源文件'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '移除'));
      await tester.pumpAndSettle();
      expect(host.workspaces, isEmpty);
    },
  );

  testWidgets(
    'failed save keeps the dialog and permission changes uncommitted',
    (tester) async {
      final host = MemoryHost()..failSave = true;
      await showPage(tester, host);
      await tester.tap(find.widgetWithText(FilledButton, '添加工作区'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('workspace-name')),
        '失败项目',
      );
      await tester.enterText(
        find.byKey(const ValueKey('workspace-directory')),
        'E:/missing',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('目录不可访问'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(host.writes, 0);
      expect(host.workspaces, isEmpty);
    },
  );

  testWidgets('narrow window supports long paths and adding a deny rule', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = MemoryHost();
    await host.add(
      id: 'example',
      name: '长路径项目',
      path: 'E:/很长的项目目录/another-long-directory/project',
      access: WorkspaceAccess.readOnly,
    );
    await showPage(tester, host);
    await tester.ensureVisible(find.text('添加目录规则'));
    await tester.tap(find.text('添加目录规则'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('workspace-directory')),
      'E:/很长的项目目录/another-long-directory/project/private',
    );
    await tester.tap(find.byKey(const ValueKey('workspace-access')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拒绝访问').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(host.workspaces.single.scopes.last.access, WorkspaceAccess.deny);
    expect(tester.takeException(), isNull);
  });
}
