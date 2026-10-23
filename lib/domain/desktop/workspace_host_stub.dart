import 'workspace_host.dart';
import '../../data/mcp_process_config.dart';

DesktopWorkspaceHost createDesktopWorkspaceHost() => _UnsupportedHost();

class _UnsupportedHost implements DesktopWorkspaceHost {
  @override
  bool get supported => false;
  @override
  Future<DesktopWorkspace> defaultWorkspace() async => _unsupported();
  @override
  Future<McpProcessConfig> processFor(String workspaceId) async =>
      _unsupported();
  Never _unsupported() =>
      throw const WorkspaceHostException('电脑工作区目前在 Windows 桌面版中使用。');
  @override
  Future<List<DesktopWorkspace>> list() async => _unsupported();
  @override
  Future<DesktopWorkspace> add({
    required String id,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async => _unsupported();
  @override
  Future<DesktopWorkspace> setScope({
    required String workspace,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async => _unsupported();
  @override
  Future<DesktopWorkspace> removeScope(String workspace, String name) async =>
      _unsupported();
  @override
  Future<void> remove(String workspace) async => _unsupported();
}
