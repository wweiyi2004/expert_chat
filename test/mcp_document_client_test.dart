import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/domain/document/document_patch.dart';
import 'package:expert_chat/domain/document/document_service_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('document edit uses only MCP tools and resources', () async {
    final adapter = _McpDocumentAdapter();
    final client = DocumentServiceClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    const connection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://mcp.example.com',
        capabilitiesDiscovered: true,
        capabilities: [GatewayCapabilityIds.documentEdit],
      ),
      apiToken: 'mcp-token',
    );
    final patch = DocumentPatch.parse({
      'schema_version': 1,
      'format': 'txt',
      'output_filename': 'edited.txt',
      'ops': [
        {'op': 'replace_text', 'find': 'before', 'replace': 'after'},
      ],
    });

    final result = await client.edit(
      connection: connection,
      fileBytes: Uint8List.fromList(utf8.encode('before')),
      filename: 'source.txt',
      patch: patch,
    );

    expect(utf8.decode(result.bytes), 'after');
    expect(result.filename, 'edited.txt');
    expect(result.contentType, 'text/plain');
    expect(adapter.toolNames, [
      'begin_upload',
      'append_upload',
      'finish_upload',
      'edit_document',
    ]);
    expect(adapter.methods.last, 'resources/read');
    expect(adapter.authorization, 'Bearer mcp-token');
    expect(adapter.protocolVersion, '2026-07-28');
  });

  test('document convert uses only MCP tools and resources', () async {
    final adapter = _McpDocumentAdapter();
    final client = DocumentServiceClient(
      dio: Dio()..httpClientAdapter = adapter,
    );
    const connection = GatewayConnection(
      config: GatewayConfig(
        enabled: true,
        baseUrl: 'https://mcp.example.com',
        capabilitiesDiscovered: true,
        capabilities: [GatewayCapabilityIds.documentConvert],
      ),
      apiToken: 'mcp-token',
    );

    final result = await client.convert(
      connection: connection,
      fileBytes: Uint8List.fromList(utf8.encode('before')),
      filename: 'source.txt',
      targetFormat: 'md',
      outputFilename: 'converted.md',
    );

    expect(utf8.decode(result.bytes), 'after');
    expect(result.filename, 'converted.md');
    expect(adapter.toolNames, [
      'begin_upload',
      'append_upload',
      'finish_upload',
      'convert_document',
    ]);
    expect(adapter.methods.last, 'resources/read');
  });

  test(
    'discovered MCP tools can be called without the document adapters',
    () async {
      final adapter = _McpDocumentAdapter();
      final client = DocumentServiceClient(
        dio: Dio()..httpClientAdapter = adapter,
      );
      const connection = GatewayConnection(
        config: GatewayConfig(
          enabled: true,
          baseUrl: 'https://mcp.example.com',
        ),
        apiToken: 'mcp-token',
      );

      final result = await client.callDiscoveredTool(
        connection: connection,
        name: 'list_documents',
        arguments: const {'limit': 10},
      );

      expect(result.text, 'ok');
      expect(result.file, isNull);
      expect(adapter.toolNames, ['list_documents']);
    },
  );
}

class _McpDocumentAdapter implements HttpClientAdapter {
  final methods = <String>[];
  final toolNames = <String>[];
  String? authorization;
  String? protocolVersion;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authorization = options.headers['Authorization']?.toString();
    protocolVersion = options.headers['MCP-Protocol-Version']?.toString();
    final request = Map<String, dynamic>.from(
      jsonDecode(await utf8.decodeStream(requestStream!)) as Map,
    );
    final method = request['method'] as String;
    methods.add(method);
    final params = Map<String, dynamic>.from(request['params'] as Map);
    Map<String, dynamic> result;
    if (method == 'tools/call') {
      final name = params['name'] as String;
      toolNames.add(name);
      final structured = switch (name) {
        'begin_upload' => {'upload_id': 'upload_1', 'offset': 0},
        'append_upload' => {
          'upload_id': 'upload_1',
          'offset': 6,
          'complete': true,
        },
        'finish_upload' => {'file_id': 'file_source', 'filename': 'source.txt'},
        'edit_document' => {
          'file_id': 'file_edited',
          'filename': 'edited.txt',
          'mime_type': 'text/plain',
          'resources': {'binary': 'expert-chat://documents/file_edited/binary'},
        },
        'convert_document' => {
          'file_id': 'file_converted',
          'filename': 'converted.md',
          'mime_type': 'text/markdown',
          'resources': {
            'binary': 'expert-chat://documents/file_converted/binary',
          },
        },
        'list_documents' => {
          'documents': [
            {'file_id': 'file_source', 'filename': 'source.txt'},
          ],
        },
        _ => throw StateError('unexpected tool: $name'),
      };
      result = {
        'resultType': 'complete',
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'structuredContent': structured,
        'isError': false,
      };
    } else if (method == 'resources/read') {
      result = {
        'resultType': 'complete',
        'contents': [
          {
            'uri': params['uri'],
            'mimeType': 'application/octet-stream',
            'blob': base64Encode(utf8.encode('after')),
          },
        ],
      };
    } else {
      throw StateError('unexpected MCP method: $method');
    }
    return ResponseBody.fromString(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
