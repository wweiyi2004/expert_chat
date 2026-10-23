import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/domain/mcp/playwright_mcp_preset.dart';
import 'package:flutter_test/flutter_test.dart';

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    final file = File(
      '${directory.path}/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    );
    if (file.existsSync()) return file.path;
    directory = directory.parent;
  }
  throw StateError('Dart SDK not found');
}

void main() {
  test(
    'browser preset preserves isolation and does not import login profiles',
    () {
      final preset = PlaywrightMcpPreset.config(windows: true);
      final restored = McpProcessConfig.fromJson(preset.toJson());
      expect(restored.requiresSession, isTrue);
      expect(restored.isPlaywright, isTrue);
      expect(restored.arguments, containsAll(['--isolated', 'msedge']));
      expect(PlaywrightMcpPreset.validate(restored), isNull);
      for (final option in [
        '--extension',
        '--cdp-endpoint=http://localhost:9222',
        '--storage-state',
        '--config',
      ]) {
        expect(
          PlaywrightMcpPreset.validate(
            McpProcessConfig(
              command: preset.command,
              arguments: [...preset.arguments, option],
              preset: 'playwright',
            ),
          ),
          isNotNull,
        );
      }
      expect(
        McpProcessConfig.fromJson({'command': 'legacy'}).requiresSession,
        isFalse,
      );
    },
  );

  late McpClient client;
  late GatewayConnection base;
  setUp(() {
    client = McpClient();
    base = GatewayConnection(
      config: const GatewayConfig(enabled: true, baseUrl: ''),
      apiToken: '',
      localProcess: McpProcessConfig(
        command: _dartExecutable(),
        arguments: [File('test/fixtures/mcp_stdio_server.dart').absolute.path],
        sessionScoped: true,
      ),
    );
    addTearDown(client.close);
  });
  Future<Map<String, dynamic>> echo(GatewayConnection connection) async =>
      jsonDecode(
            (await client.callTool(
              connection: connection,
              name: 'echo',
              arguments: {},
            )).text,
          )
          as Map<String, dynamic>;

  test(
    'discovery works without borrowing a session, calls require ownership',
    () async {
      expect((await client.discover(connection: base)).tools, hasLength(2));
      await expectLater(echo(base), throwsA(isA<McpClientException>()));
      expect((await echo(base.forSession('a')))['calls'], 1);
    },
  );

  test(
    'session isolation never bypasses existing computer-use policy',
    () async {
      final computer = GatewayConnection(
        config: base.config,
        apiToken: '',
        localProcess: base.localProcess,
        computerUse: true,
      ).forSession('computer');
      await expectLater(
        client.callTool(
          connection: computer,
          name: 'click',
          arguments: {'target': 'desktop'},
        ),
        throwsA(
          isA<McpClientException>().having(
            (e) => e.code,
            'code',
            'computer_use_policy',
          ),
        ),
      );
    },
  );

  test(
    'conversation and child browser states are distinct; stop A preserves B',
    () async {
      final a = base.forSession('a');
      final child = base.forSession('a', agentId: 'child');
      final b = base.forSession('b');
      final first = await echo(a),
          childFirst = await echo(child),
          other = await echo(b);
      expect({first['pid'], childFirst['pid'], other['pid']}, hasLength(3));
      expect((await echo(a))['calls'], 2);
      await client.stopLocalSession('a');
      expect((await echo(b))['pid'], other['pid']);
      expect((await echo(a))['pid'], isNot(first['pid']));
      expect((await echo(child))['pid'], isNot(childFirst['pid']));
    },
  );

  test(
    'stopping conversation cancels active and queued calls without replay',
    () async {
      final a = base.forSession('a');
      await echo(a);
      final token = CancelToken();
      final running = client.callTool(
        connection: a,
        name: 'slow',
        arguments: {},
        cancelToken: token,
      );
      final queued = client.callTool(
        connection: a,
        name: 'echo',
        arguments: {},
      );
      final runningCheck = expectLater(
        running,
        throwsA(isA<McpClientException>()),
      );
      final queuedCheck = expectLater(
        queued,
        throwsA(isA<McpClientException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await client.stopLocalSession('a');
      await Future.wait([runningCheck, queuedCheck]);
      expect((await echo(a))['calls'], 1);
    },
  );
}
