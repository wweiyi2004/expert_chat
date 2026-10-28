import '../desktop/workspace_host.dart';
import '../../data/mcp_process_config.dart';
import 'host_client.dart';
import 'wire_models.dart';

class HostWorkspaceClient implements DesktopWorkspaceHost {
  HostWorkspaceClient(this.client);
  final HostClient client;
  @override
  bool get supported => true;
  Future<Object?> _call(String operation, Map<String, Object?> args) =>
      client.call('workspace', operation, args);
  @override
  Future<DesktopWorkspace> defaultWorkspace() async =>
      DesktopWorkspace.fromJson(wireMap(await _call('defaultWorkspace', {})));
  @override
  Future<List<DesktopWorkspace>> list() async =>
      wireRows(await _call('list', {})).map(DesktopWorkspace.fromJson).toList();
  @override
  Future<McpProcessConfig> processFor(String workspaceId) async =>
      McpProcessConfig.fromJson(
        wireMap(await _call('processFor', {'workspaceId': workspaceId})),
      );
  @override
  Future<DesktopWorkspace> add({
    required String id,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async => DesktopWorkspace.fromJson(
    wireMap(
      await _call('add', {
        'id': id,
        'name': name,
        'path': path,
        'access': access.wireValue,
      }),
    ),
  );
  @override
  Future<DesktopWorkspace> setScope({
    required String workspace,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async => DesktopWorkspace.fromJson(
    wireMap(
      await _call('setScope', {
        'workspace': workspace,
        'name': name,
        'path': path,
        'access': access.wireValue,
      }),
    ),
  );
  @override
  Future<DesktopWorkspace> removeScope(String workspace, String name) async =>
      DesktopWorkspace.fromJson(
        wireMap(
          await _call('removeScope', {'workspace': workspace, 'name': name}),
        ),
      );
  @override
  Future<void> remove(String workspace) async {
    await _call('remove', {'workspace': workspace});
  }
}
