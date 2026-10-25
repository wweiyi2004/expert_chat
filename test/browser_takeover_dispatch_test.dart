import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/state/controlled_browser.dart';

String dartExecutable() {
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
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'user takeover rejects model calls and stale queue even after release, manual same instance remains',
    () async {
      final client = McpClient();
      final container = ProviderContainer(
        overrides: [mcpClientProvider.overrideWithValue(client)],
      );
      addTearDown(() async {
        container.dispose();
        await client.close();
      });
      final base = GatewayConnection(
        config: const GatewayConfig(enabled: true, baseUrl: ''),
        apiToken: '',
        localProcess: McpProcessConfig(
          command: dartExecutable(),
          arguments: [
            File('test/fixtures/mcp_stdio_server.dart').absolute.path,
            '--isolated',
          ],
          preset: 'playwright',
          sessionScoped: true,
        ),
      );
      final owned = base.forSession('owned', agentId: 'child');
      Future<McpToolResult> call(String name, {bool manual = false}) =>
          client.callTool(
            connection: owned,
            name: name,
            arguments: {},
            userInitiated: manual,
          );
      final initial = jsonDecode((await call('echo')).text) as Map;
      final running = call('slow');
      final queued = call('echo');
      final stale = expectLater(
        queued,
        throwsA(
          isA<McpClientException>().having(
            (e) => e.code,
            'code',
            'browser_stale_lease',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      container
          .read(controlledBrowserProvider.notifier)
          .takeover('owned', true);
      await expectLater(
        call('echo'),
        throwsA(
          isA<McpClientException>().having(
            (e) => e.code,
            'code',
            'browser_user_takeover',
          ),
        ),
      );
      final manual = call('echo', manual: true);
      container
          .read(controlledBrowserProvider.notifier)
          .takeover('owned', false);
      await running;
      await stale;
      final after = jsonDecode((await manual).text) as Map;
      expect(after['pid'], initial['pid']);
      expect(after['calls'], 3);
      final fresh = jsonDecode((await call('echo')).text) as Map;
      expect(fresh['calls'], 4);
      expect(fresh['pid'], initial['pid']);
    },
  );
}
