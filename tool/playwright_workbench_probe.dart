import 'dart:convert';
import 'dart:io';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/domain/mcp/playwright_mcp_preset.dart';

Future<void> main() async {
  final client = McpClient();
  final connection = GatewayConnection(
    config: const GatewayConfig(enabled: true, baseUrl: ''),
    apiToken: '',
    localProcess: PlaywrightMcpPreset.config(
      windows: Platform.isWindows,
      headless: true,
    ),
  ).forSession('workbench-probe');
  try {
    final discovered = await client.discover(connection: connection);
    for (final tool in discovered.tools.where(
      (t) => {
        'browser_click',
        'browser_type',
        'browser_snapshot',
        'browser_take_screenshot',
      }.contains(t.name),
    )) {
      stdout.writeln(
        jsonEncode({'name': tool.name, 'schema': tool.inputSchema}),
      );
    }
  } finally {
    await client.close();
  }
}
