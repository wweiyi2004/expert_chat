import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'workspace_host.dart';
import '../../data/mcp_process_config.dart';

DesktopWorkspaceHost createDesktopWorkspaceHost() => CliDesktopWorkspaceHost();

/// The desktop service owns the registry and every authorization decision.
/// Never resolve this executable via the project directory or PATH.
class CliDesktopWorkspaceHost implements DesktopWorkspaceHost {
  CliDesktopWorkspaceHost({
    this.executable,
    this.dataDirectory,
    this.timeout = const Duration(seconds: 15),
  });
  final String? executable;
  final String? dataDirectory;
  final Duration timeout;

  @override
  bool get supported => Platform.isWindows || executable != null;

  Future<String> _program() async {
    if (!supported) {
      throw const WorkspaceHostException('电脑工作区目前在 Windows 桌面版中使用。');
    }
    final program =
        executable ??
        p.join(p.dirname(Platform.resolvedExecutable), 'expert-desktop.exe');
    if (!await File(program).exists()) {
      throw const WorkspaceHostException(
        '运行包缺少 expert-desktop.exe 文件服务，请使用完整运行包；工作区操作无需启动 GUI。',
      );
    }
    return program;
  }

  @override
  Future<McpProcessConfig> processFor(String workspaceId) async =>
      McpProcessConfig(
        command: await _program(),
        arguments: [
          if (dataDirectory != null) ...['--data-dir', dataDirectory!],
          'serve',
          workspaceId,
        ],
      );

  @override
  Future<DesktopWorkspace> defaultWorkspace() async =>
      DesktopWorkspace.fromJson(
        Map<String, dynamic>.from(await _run(['workspace', 'default']) as Map),
      );

  Future<dynamic> _run(List<String> arguments) async {
    final program = await _program();
    final process = await Process.start(program, [
      if (dataDirectory != null) ...['--data-dir', dataDirectory!],
      ...arguments,
    ], runInShell: false);
    await process.stdin.close();
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    late int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      await Future.wait([output, errors]);
      throw const WorkspaceHostException('操作未在时限内确认。请刷新工作区状态后再决定是否重试。');
    }
    final text = await output;
    final error = await errors;
    if (code != 0) {
      throw WorkspaceHostException(_describe(error.trim()));
    }
    return jsonDecode(text);
  }

  static String _describe(String error) {
    if (error.contains('Scope directory must exist')) {
      return '目录不存在或无法访问，请重新选择。';
    }
    if (error.contains('overlap the desktop configuration directory')) {
      return '工作区不能包含执行端配置目录，请选择具体的项目文件夹。';
    }
    if (error.contains('already has a rule')) return '这个目录已有规则，请编辑已有规则。';
    if (error.contains('Workspace not found')) return '工作区已被移除，请刷新列表。';
    if (error.contains('Scope not found')) return '目录规则已被移除，请刷新列表。';
    return error.isEmpty
        ? '电脑执行端未完成操作。'
        : error.replaceFirst(RegExp(r'^Error:\s*'), '');
  }

  @override
  Future<List<DesktopWorkspace>> list() async => [
    for (final value in await _run(['workspace', 'list']) as List)
      DesktopWorkspace.fromJson(Map<String, dynamic>.from(value as Map)),
  ]..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<DesktopWorkspace> add({
    required String id,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async => DesktopWorkspace.fromJson(
    Map<String, dynamic>.from(
      await _run([
            'workspace',
            'add',
            id,
            '--name',
            name,
            '--path',
            path,
            '--access',
            access.wireValue,
          ])
          as Map,
    ),
  );

  @override
  Future<DesktopWorkspace> setScope({
    required String workspace,
    required String name,
    required String path,
    required WorkspaceAccess access,
  }) async => DesktopWorkspace.fromJson(
    Map<String, dynamic>.from(
      await _run([
            'scope',
            'set',
            workspace,
            name,
            '--path',
            path,
            '--access',
            access.wireValue,
          ])
          as Map,
    ),
  );

  @override
  Future<DesktopWorkspace> removeScope(String workspace, String name) async =>
      DesktopWorkspace.fromJson(
        Map<String, dynamic>.from(
          await _run(['scope', 'remove', workspace, name]) as Map,
        ),
      );

  @override
  Future<void> remove(String workspace) async {
    await _run(['workspace', 'remove', workspace]);
  }
}
