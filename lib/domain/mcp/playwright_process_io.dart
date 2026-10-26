import 'dart:io';

import '../../data/mcp_process_config.dart';
import 'playwright_mcp_preset.dart';

/// Resolves npm's Windows script launcher without composing a cmd.exe command.
/// npm scripts otherwise fail when launched as a native executable by Dart.
Future<
  ({
    String command,
    List<String> arguments,
    String? directory,
    Map<String, String>? environment,
  })
>
prepareMcpProcess(McpProcessConfig config) async {
  var command = config.command.trim();
  var args = config.arguments;
  var directory = config.workingDirectory.trim();
  Map<String, String>? environment = config.environment.isEmpty
      ? null
      : {...Platform.environment, ...config.environment};
  if (config.isPlaywright) {
    final error = PlaywrightMcpPreset.validate(config);
    if (error != null) throw StateError(error);
    args = PlaywrightMcpPreset.runtimeArguments(config);
    // Do not let an inherited CDP endpoint, extension token, profile or config
    // override the isolated preset. Other runtime/network variables stay intact.
    environment = Map<String, String>.from(
      environment ?? Platform.environment,
    )..removeWhere((key, _) => key.toUpperCase().startsWith('PLAYWRIGHT_MCP_'));
    if (directory.isEmpty) {
      directory = (await Directory.systemTemp.createTemp(
        'expert-chat-browser-',
      )).path;
    }
    if (Platform.isWindows &&
        {'npx', 'npx.cmd', 'npx.exe'}.contains(command.toLowerCase())) {
      final paths = (Platform.environment['PATH'] ?? '').split(';');
      File? node;
      File? npx;
      for (final path in paths) {
        final trimmed = path.replaceAll('"', '').trim();
        if (trimmed.isEmpty) continue;
        final candidate = File('$trimmed/node.exe');
        if (node == null && candidate.existsSync()) node = candidate;
        final script = File('$trimmed/node_modules/npm/bin/npx-cli.js');
        if (npx == null && script.existsSync()) npx = script;
      }
      if (node == null || npx == null) {
        throw StateError('未找到 Node.js 和 npm。请安装 Node.js 18 或更高版本，重启软件后重新发现工具。');
      }
      command = node.path;
      args = [npx.path, ...args];
    }
  }
  return (
    command: command,
    arguments: args,
    directory: directory.isEmpty ? null : directory,
    environment: environment,
  );
}
