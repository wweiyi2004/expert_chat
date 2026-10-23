import 'dart:io';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/domain/desktop/workspace_host_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('unknown permission never silently becomes writable', () {
    expect(() => WorkspaceAccess.parse('future-mode'), throwsFormatException);
  });

  test('missing packaged executable gives a useful error', () async {
    final host = CliDesktopWorkspaceHost(
      executable: p.join(
        Directory.systemTemp.path,
        'missing-desktop-service-4027.exe',
      ),
    );
    await expectLater(
      host.list(),
      throwsA(
        isA<WorkspaceHostException>().having(
          (e) => e.message,
          'message',
          contains('未包含电脑执行端'),
        ),
      ),
    );
  });

  // Explicit opt-in: the Rust executable is built by the desktop check first.
  if (const bool.fromEnvironment('DESKTOP_WORKSPACE_NATIVE_TEST')) {
    test(
      'Dart client and Rust CLI share persisted permissions with Unicode paths',
      () async {
        final root = await Directory.systemTemp.createTemp('workspace-ui-');
        addTearDown(() => root.delete(recursive: true));
        final project = await Directory(
          p.join(root.path, '中文 project & files'),
        ).create();
        final source = await Directory(p.join(project.path, 'src')).create();
        final executable = p.absolute(
          'next',
          'target',
          'debug',
          Platform.isWindows ? 'expert-desktop.exe' : 'expert-desktop',
        );
        final host = CliDesktopWorkspaceHost(
          executable: executable,
          dataDirectory: p.join(root.path, 'state'),
        );
        expect(await host.list(), isEmpty);
        final workspace = await host.add(
          id: 'ui-test',
          name: '界面项目',
          path: project.path,
          access: WorkspaceAccess.readOnly,
        );
        expect(workspace.scopes.single.access, WorkspaceAccess.readOnly);
        await host.setScope(
          workspace: workspace.id,
          name: 'source',
          path: source.path,
          access: WorkspaceAccess.readWrite,
        );
        final reopened = CliDesktopWorkspaceHost(
          executable: executable,
          dataDirectory: p.join(root.path, 'state'),
        );
        expect(
          (await reopened.list()).single.scopes.last.access,
          WorkspaceAccess.readWrite,
        );
        await host.setScope(
          workspace: workspace.id,
          name: 'source',
          path: source.path,
          access: WorkspaceAccess.deny,
        );
        expect(
          (await reopened.list()).single.scopes.last.access,
          WorkspaceAccess.deny,
        );
        await host.removeScope(workspace.id, 'source');
        expect((await host.list()).single.scopes, hasLength(1));
        await host.remove(workspace.id);
        expect(await host.list(), isEmpty);
        expect(await project.exists(), isTrue);
      },
    );
  }
}
