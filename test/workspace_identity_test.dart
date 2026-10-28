import 'package:expert_chat/domain/desktop/workspace_identity.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sidebar combines duplicate locations only when their grants match', () {
    DesktopWorkspace workspace(
      String id,
      String path,
      WorkspaceAccess access,
    ) => DesktopWorkspace(
      id: id,
      name: 'Project',
      root: path,
      scopes: [WorkspaceScope(name: 'root', path: path, access: access)],
    );
    final a = workspace('a', r'E:\Project', WorkspaceAccess.readWrite);
    final b = workspace('b', r'E:\Project', WorkspaceAccess.readWrite);
    final restricted = workspace('c', r'E:\Project', WorkspaceAccess.readOnly);
    expect(workspaceNavigationIdentity(a), workspaceNavigationIdentity(b));
    expect(
      workspaceNavigationIdentity(a),
      isNot(workspaceNavigationIdentity(restricted)),
    );
  });
  test(
    'Windows extended path, separators, case and trailing slash share identity',
    () {
      final expected = workspacePathIdentity(
        r'E:\wweiyi\Project\AI',
        windows: true,
      );
      for (final path in [
        r'\\?\E:\wweiyi\Project\AI',
        'e:/wweiyi/Project/AI/',
        r'E:\wweiyi\Project\other\..\AI',
      ]) {
        expect(workspacePathIdentity(path, windows: true), expected);
      }
      expect(
        workspacePathIdentity(r'\\?\UNC\server\share\folder', windows: true),
        workspacePathIdentity(r'\\SERVER\share\folder\', windows: true),
      );
    },
  );
  test(
    'POSIX paths remain case sensitive and distinct roots remain separate',
    () {
      expect(
        workspacePathIdentity('/tmp/AI', windows: false),
        isNot(workspacePathIdentity('/tmp/ai', windows: false)),
      );
      expect(
        workspacePathIdentity(r'E:\one\AI', windows: true),
        isNot(workspacePathIdentity(r'E:\two\AI', windows: true)),
      );
    },
  );
}
