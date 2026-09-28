import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/domain/mcp/stdio_transport.dart';
import 'package:flutter_test/flutter_test.dart';

String dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    final candidate = File(
      '${directory.path}/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
    );
    if (candidate.existsSync()) return candidate.path;
    directory = directory.parent;
  }
  throw StateError('Dart SDK was not found beside Flutter test runtime');
}

void main() {
  late McpClient client;
  late McpProcessConfig process;
  setUp(() {
    client = McpClient();
    process = McpProcessConfig(
      command: dartExecutable(),
      arguments: [File('test/fixtures/mcp_stdio_server.dart').absolute.path],
    );
    addTearDown(client.close);
  });
  GatewayConnection connection({McpProcessConfig? config}) => GatewayConnection(
    config: const GatewayConfig(enabled: true, baseUrl: ''),
    apiToken: '',
    localProcess: config ?? process,
  );

  test(
    'legacy initialization, pagination and shared process for successive calls',
    () async {
      final server = await client.discover(connection: connection());
      expect(server.name, 'fixture');
      expect(server.tools.map((t) => t.name), ['echo', 'other']);
      final a = await client.callTool(
        connection: connection(),
        name: 'echo',
        arguments: {'text': '中文 空格; & literal'},
      );
      final b = await client.callTool(
        connection: connection(),
        name: 'echo',
        arguments: {},
      );
      expect(jsonDecode(a.text)['args']['text'], '中文 空格; & literal');
      expect(jsonDecode(b.text)['calls'], 2);
      expect(jsonDecode(a.text)['pid'], jsonDecode(b.text)['pid']);
    },
  );

  test(
    'stop closes process; next explicit call starts a fresh connection',
    () async {
      final a = await client.callTool(
        connection: connection(),
        name: 'echo',
        arguments: {},
      );
      await client.stopLocalServers();
      final b = await client.callTool(
        connection: connection(),
        name: 'echo',
        arguments: {},
      );
      expect(jsonDecode(b.text)['calls'], 1);
      expect(jsonDecode(a.text)['pid'], isNot(jsonDecode(b.text)['pid']));
    },
  );

  test('cancel stops waiting and does not replay the mutation', () async {
    await client.discover(connection: connection());
    final token = CancelToken();
    final request = client.callTool(
      connection: connection(),
      name: 'slow',
      arguments: {},
      cancelToken: token,
    );
    final assertion = expectLater(request, throwsA(isA<McpClientException>()));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    token.cancel();
    await assertion;
    final next = await client.callTool(
      connection: connection(),
      name: 'echo',
      arguments: {},
    );
    expect(jsonDecode(next.text)['calls'], 1);
  });

  for (final name in ['die', 'invalid']) {
    test('$name breaks the connection without automatic replay', () async {
      await expectLater(
        client.callTool(connection: connection(), name: name, arguments: {}),
        throwsA(isA<McpClientException>()),
      );
      final next = await client.callTool(
        connection: connection(),
        name: 'echo',
        arguments: {},
      );
      expect(jsonDecode(next.text)['calls'], 1);
    });
  }

  test('transport timeout retires connection', () async {
    final transport = StdioTransport(process);
    addTearDown(transport.close);
    await transport.initialize();
    await expectLater(
      transport.request('tools/call', {
        'name': 'slow',
        'arguments': {},
      }, timeout: const Duration(milliseconds: 150)),
      throwsA(isA<Exception>()),
    );
    expect(transport.isAlive, isFalse);
  });

  test('unsupported negotiated protocol fails discovery', () async {
    await expectLater(
      client.discover(
        connection: connection(
          config: McpProcessConfig(
            command: process.command,
            arguments: [...process.arguments, 'bad-version'],
          ),
        ),
      ),
      throwsA(isA<McpClientException>()),
    );
  });

  test('local configuration roundtrip preserves HTTP defaults', () {
    final local = CustomMcpServer(
      id: 'desktop',
      name: 'Desktop',
      baseUrl: '',
      localProcess: process,
      computerUse: true,
    );
    final loaded = CustomMcpServer.fromJson(local.toJson());
    expect(loaded.isConfigured, isTrue);
    expect(loaded.localProcess!.identity, process.identity);
    expect(loaded.allowForeground, isFalse);
    expect(
      CustomMcpServer.fromJson({
        'id': 'http',
        'name': 'HTTP',
        'baseUrl': 'https://example.com',
      }).localProcess,
      isNull,
    );
  });
}
