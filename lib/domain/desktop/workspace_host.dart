import '../../data/mcp_process_config.dart';

const defaultDesktopWorkspaceId = 'builtin-default';

enum WorkspaceAccess {
  deny('deny', '拒绝访问'),
  readOnly('read-only', '只读'),
  readWrite('read-write', '读写');

  const WorkspaceAccess(this.wireValue, this.label);
  final String wireValue;
  final String label;

  static WorkspaceAccess parse(String value) => values.firstWhere(
    (access) => access.wireValue == value,
    orElse: () => throw FormatException('不支持的目录权限：$value'),
  );
}

class WorkspaceScope {
  const WorkspaceScope({
    required this.name,
    required this.path,
    required this.access,
  });
  final String name;
  final String path;
  final WorkspaceAccess access;

  factory WorkspaceScope.fromJson(Map<String, dynamic> json) => WorkspaceScope(
    name: json['name'] as String,
    path: json['path'] as String,
    access: WorkspaceAccess.parse(json['access'] as String),
  );
}

class DesktopWorkspace {
  const DesktopWorkspace({
    required this.id,
    required this.name,
    required this.root,
    required this.scopes,
  });
  final String id;
  final String name;
  final String root;
  final List<WorkspaceScope> scopes;

  factory DesktopWorkspace.fromJson(Map<String, dynamic> json) =>
      DesktopWorkspace(
        id: json['id'] as String,
        name: json['name'] as String,
        root: json['root'] as String,
        scopes:
            [
              for (final value in (json['scopes'] as Map).values)
                WorkspaceScope.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
            ]..sort((a, b) {
              if (a.name == b.name) return 0;
              if (a.name == 'root') return -1;
              if (b.name == 'root') return 1;
              return a.path.compareTo(b.path);
            }),
      );
}

abstract interface class DesktopWorkspaceHost {
  bool get supported;
  Future<DesktopWorkspace> defaultWorkspace();
  Future<McpProcessConfig> processFor(String workspaceId);
  Future<List<DesktopWorkspace>> list();
  Future<DesktopWorkspace> add({
    required String id,
    required String name,
    required String path,
    required WorkspaceAccess access,
  });
  Future<DesktopWorkspace> setScope({
    required String workspace,
    required String name,
    required String path,
    required WorkspaceAccess access,
  });
  Future<DesktopWorkspace> removeScope(String workspace, String name);
  Future<void> remove(String workspace);
}

class WorkspaceHostException implements Exception {
  const WorkspaceHostException(this.message);
  final String message;
  @override
  String toString() => message;
}
