import 'dart:convert';
import 'dart:io';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/domain/mcp/playwright_mcp_preset.dart';

/// Opt-in real isolated Playwright probe; serves only a local synthetic page.
/// Does not open or inspect any user browser, credentials or existing task.
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response.headers.contentType = ContentType.html;
    request.response.write(
      '<!doctype html><title>Workbench isolated fixture</title><label>Name<input id="name"></label><button id="apply" onclick="document.getElementById(\'out\').textContent=document.getElementById(\'name\').value">Apply</button><p id="out">initial</p>',
    );
    request.response.close();
  });
  final client = McpClient();
  final base = GatewayConnection(
    config: const GatewayConfig(enabled: true, baseUrl: ''),
    apiToken: '',
    localProcess: PlaywrightMcpPreset.config(
      windows: Platform.isWindows,
      headless: true,
    ),
  );
  final owned = base.forSession('workbench-smoke', agentId: 'child-observer');
  Future<McpToolResult> call(String name, Map<String, dynamic> arguments) =>
      client.callTool(connection: owned, name: name, arguments: arguments);
  try {
    final catalog = await client.discover(connection: owned);
    for (final name in [
      'browser_navigate',
      'browser_snapshot',
      'browser_type',
      'browser_click',
      'browser_take_screenshot',
    ]) {
      if (!catalog.tools.any((tool) => tool.name == name)) {
        throw StateError('Missing actual tool $name');
      }
    }
    final type = catalog.tools.firstWhere(
      (tool) => tool.name == 'browser_type',
    );
    if (!(type.inputSchema['properties'] as Map).containsKey('target')) {
      throw StateError('Pinned target schema differs');
    }
    await call('browser_navigate', {'url': 'http://127.0.0.1:${server.port}/'});
    final initial = await call('browser_snapshot', {});
    if (!initial.text.contains('initial')) {
      throw StateError('Initial fixture not observed');
    }
    // These are the exact same client/session/agent that the workbench manual
    // takeover path uses. The app-side takeover gate is separately tested.
    await call('browser_type', {
      'target': '#name',
      'text': 'manual-user-takeover',
    });
    await call('browser_click', {'target': '#apply'});
    final observed = await call('browser_snapshot', {});
    if (!observed.text.contains('manual-user-takeover')) {
      throw StateError('Manual edit not in same browser');
    }
    final image = await call('browser_take_screenshot', {'scale': 'css'});
    final images = image.content
        .where((item) => item['type'] == 'image' && item['data'] is String)
        .toList();
    if (images.isEmpty ||
        base64Decode(images.first['data'] as String).length < 100) {
      throw StateError('No real screenshot');
    }
    final released = await call('browser_snapshot', {});
    if (!released.text.contains('manual-user-takeover')) {
      throw StateError('Released observation lost user work');
    }
    final other = base.forSession(
      'workbench-smoke',
      agentId: 'different-agent',
    );
    await client.callTool(
      connection: other,
      name: 'browser_navigate',
      arguments: {'url': 'http://127.0.0.1:${server.port}/'},
    );
    final isolated = await client.callTool(
      connection: other,
      name: 'browser_snapshot',
      arguments: {},
    );
    if (isolated.text.contains('manual-user-takeover')) {
      throw StateError('Agent browser isolation failed');
    }
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'package': PlaywrightMcpPreset.package,
        'same_session_manual_actions': true,
        'fresh_snapshot_after_release': true,
        'real_screenshot_bytes': base64Decode(
          images.first['data'] as String,
        ).length,
        'different_agent_isolated': true,
        'note':
            'Application takeover refusal/feedback validated by separate state/controller tests; embedded WebView remains independent.',
      }),
    );
  } finally {
    await client.close();
    await server.close(force: true);
  }
}
