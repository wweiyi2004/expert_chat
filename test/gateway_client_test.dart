import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/gateway/gateway_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('discovers document tools from the MCP server', () async {
    final adapter = _McpAdapter();
    final client = GatewayClient(dio: Dio()..httpClientAdapter = adapter);
    const connection = GatewayConnection(
      config: GatewayConfig(enabled: true, baseUrl: 'https://mcp.example.com/'),
      apiToken: 'shared-token',
    );

    final manifest = await client.discover(connection: connection);

    expect(adapter.paths, ['/mcp', '/mcp']);
    expect(adapter.methods, ['server/discover', 'tools/list']);
    expect(adapter.authorization, 'Bearer shared-token');
    expect(adapter.protocolVersion, '2026-07-28');
    expect(manifest.protocolVersion, 1);
    expect(manifest.gatewayVersion, '1.0.0');
    expect(manifest.supports(GatewayCapabilityIds.longTasks), isFalse);
    expect(manifest.supports(GatewayCapabilityIds.documentEdit), isTrue);
    expect(
      manifest.metadata(GatewayCapabilityIds.documentEdit)['transport'],
      'mcp',
    );
    expect(manifest.tools.map((tool) => tool.name), [
      'begin_upload',
      'edit_document',
      'convert_document',
      'list_documents',
    ]);
  });

  test('discovered MCP tools survive JSON round trip', () {
    const config = GatewayConfig(
      enabled: true,
      baseUrl: 'https://mcp.example.com',
      capabilitiesDiscovered: true,
      capabilities: [GatewayCapabilityIds.documentEdit],
      mcpTools: [
        DiscoveredMcpTool(
          name: 'list_documents',
          description: '列出文档',
          inputSchema: {
            'type': 'object',
            'properties': {
              'limit': {'type': 'integer'},
            },
          },
        ),
      ],
    );
    final restored = GatewayConfig.fromJson(config.toJson());
    expect(restored.mcpTools, hasLength(1));
    expect(restored.mcpTools.single.name, 'list_documents');
    expect(restored.mcpTools.single.inputSchema['type'], 'object');
  });

  test('discovered capability list is authoritative', () {
    const undiscovered = GatewayConfig(
      enabled: true,
      baseUrl: 'https://gateway.example.com',
    );
    expect(undiscovered.supports(GatewayCapabilityIds.documentEdit), isFalse);

    final discovered = undiscovered.copyWith(
      capabilitiesDiscovered: true,
      capabilities: const [GatewayCapabilityIds.longTasks],
    );
    expect(discovered.supports(GatewayCapabilityIds.longTasks), isTrue);
    expect(discovered.supports(GatewayCapabilityIds.documentEdit), isFalse);
  });

  test('optional upload URL normalizes and survives JSON round trip', () {
    const config = GatewayConfig(
      enabled: true,
      baseUrl: 'https://gateway.example.com/',
      uploadBaseUrl: 'https://upload.example.com///',
    );

    expect(config.normalizedBaseUrl, 'https://gateway.example.com');
    expect(config.normalizedUploadBaseUrl, 'https://upload.example.com');
    expect(config.effectiveUploadBaseUrl, 'https://upload.example.com');
    expect(config.hasDedicatedUploadBaseUrl, isTrue);

    final restored = GatewayConfig.fromJson(config.toJson());
    expect(restored.uploadBaseUrl, config.uploadBaseUrl);
    expect(restored.effectiveUploadBaseUrl, 'https://upload.example.com');

    final legacy = GatewayConfig.fromJson(const {
      'enabled': true,
      'baseUrl': 'https://gateway.example.com',
    });
    expect(legacy.uploadBaseUrl, isEmpty);
    expect(legacy.effectiveUploadBaseUrl, legacy.normalizedBaseUrl);
  });
}

class _McpAdapter implements HttpClientAdapter {
  final paths = <String>[];
  final methods = <String>[];
  String? authorization;
  String? protocolVersion;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    authorization = options.headers['Authorization']?.toString();
    protocolVersion = options.headers['MCP-Protocol-Version']?.toString();
    final body = jsonDecode(await utf8.decodeStream(requestStream!));
    final method = (body as Map<String, dynamic>)['method'] as String;
    methods.add(method);
    final result = switch (method) {
      'server/discover' => {
        'resultType': 'complete',
        'supportedVersions': ['2026-07-28'],
        'capabilities': {'tools': {}, 'resources': {}},
        '_meta': {
          'io.modelcontextprotocol/serverInfo': {
            'name': 'Expert Chat MCP',
            'version': '1.0.0',
          },
        },
      },
      'tools/list' => {
        'resultType': 'complete',
        'tools': [
          {
            'name': 'begin_upload',
            'description': '开始上传',
            'inputSchema': {'type': 'object'},
          },
          {
            'name': 'edit_document',
            'description': '编辑文档',
            'inputSchema': {'type': 'object'},
          },
          {
            'name': 'convert_document',
            'description': '转换文档',
            'inputSchema': {'type': 'object'},
          },
          {
            'name': 'list_documents',
            'description': '列出文档',
            'inputSchema': {'type': 'object'},
          },
        ],
      },
      _ => throw StateError('unexpected MCP method: $method'),
    };
    return ResponseBody.fromString(
      jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
