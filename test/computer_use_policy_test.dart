import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/computer_use_policy.dart';
import 'package:expert_chat/domain/mcp/mcp_host_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const connection = GatewayConnection(
    config: GatewayConfig(enabled: true),
    apiToken: '',
    computerUse: true,
  );
  const target = {'pid': 123, 'window_id': 456};
  late ComputerUsePolicy policy;
  setUp(() => policy = ComputerUsePolicy());
  test('only explicitly offered desktop tools reach the model', () {
    final tools = McpHostTools.mergeForModel(
      documentTools: [],
      customServers: [
        const CustomMcpServer(
          id: 'desktop',
          name: 'Desktop',
          baseUrl: 'http://localhost',
          computerUse: true,
          toolsDiscovered: true,
          tools: [
            DiscoveredMcpTool(name: 'click'),
            DiscoveredMcpTool(name: 'kill_app'),
            DiscoveredMcpTool(name: 'set_config'),
          ],
        ),
      ],
    );
    expect(tools.map((t) => t.originalName), ['click']);
    expect(
      tools.single.tool.inputSchema['required'],
      containsAll(['pid', 'window_id']),
    );
  });
  test('an action requires a recent exact-window observation', () {
    expect(() => policy.prepare(connection, 'click', target), throwsStateError);
    policy.observed(connection, target);
    expect(
      () => policy.prepare(connection, 'click', {'pid': 123, 'window_id': 999}),
      throwsStateError,
    );
    expect(
      policy.prepare(connection, 'click', target)['delivery_mode'],
      'background',
    );
    expect(() => policy.prepare(connection, 'click', target), throwsStateError);
  });
  test('background refusal does not grant foreground permission', () {
    policy.observed(connection, target);
    policy.refused(connection, target);
    expect(
      () => policy.prepare(connection, 'click', {
        ...target,
        'delivery_mode': 'foreground',
      }),
      throwsStateError,
    );
  });
  test(
    'foreground needs both explicit setting and previous background refusal',
    () {
      const allowed = GatewayConnection(
        config: GatewayConfig(enabled: true),
        apiToken: '',
        computerUse: true,
        allowForeground: true,
      );
      policy.observed(allowed, target);
      expect(
        () => policy.prepare(allowed, 'click', {
          ...target,
          'delivery_mode': 'foreground',
        }),
        throwsStateError,
      );
      policy.refused(allowed, target);
      expect(
        policy.prepare(allowed, 'click', {
          ...target,
          'delivery_mode': 'foreground',
        })['delivery_mode'],
        'foreground',
      );
    },
  );
  test(
    'reset invalidates observations; screenshot cannot write arbitrary files',
    () {
      policy.observed(connection, target);
      policy.reset();
      expect(
        () =>
            policy.prepare(connection, 'set_value', {...target, 'value': 'x'}),
        throwsStateError,
      );
      final args = policy.prepare(connection, 'get_window_state', {
        ...target,
        'screenshot_out_file': 'private.png',
      });
      expect(args.containsKey('screenshot_out_file'), isFalse);
      expect(args['max_dimension'], 1280);
    },
  );
}
