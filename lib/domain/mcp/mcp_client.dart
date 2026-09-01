import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';

const _protocolVersion = '2026-07-28';

class McpClientException implements Exception {
  const McpClientException(this.message, {this.code = 'mcp_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class McpToolDefinition {
  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory McpToolDefinition.fromJson(Map<String, dynamic> json) =>
      McpToolDefinition(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        inputSchema: _stringMap(json['inputSchema']),
      );
}

class McpServerDescription {
  const McpServerDescription({
    required this.name,
    required this.version,
    required this.tools,
  });

  final String name;
  final String version;
  final List<McpToolDefinition> tools;
}

class McpToolResult {
  const McpToolResult({
    required this.content,
    required this.structuredContent,
    required this.isError,
  });

  final List<Map<String, dynamic>> content;
  final Map<String, dynamic> structuredContent;
  final bool isError;

  String get text => [
    for (final item in content)
      if (item['type'] == 'text' && item['text'] is String)
        item['text'] as String,
  ].join('\n');
}

/// Minimal modern MCP 2026-07-28 client over Streamable HTTP.
///
/// The modern protocol is stateless: every request carries protocol and client
/// metadata, so the Flutter app does not maintain an MCP session identifier.
class McpClient {
  McpClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  int _nextId = 0;

  Future<McpServerDescription> discover({
    required GatewayConnection connection,
    CancelToken? cancelToken,
  }) async {
    final discovered = await _request(
      connection: connection,
      method: 'server/discover',
      params: const {},
      cancelToken: cancelToken,
    );
    final meta = _stringMap(discovered['_meta']);
    final serverInfo = _stringMap(
      meta['io.modelcontextprotocol/serverInfo'],
    );
    final listed = await _request(
      connection: connection,
      method: 'tools/list',
      params: const {},
      cancelToken: cancelToken,
    );
    final tools = <McpToolDefinition>[
      for (final raw in listed['tools'] is List
          ? listed['tools'] as List<dynamic>
          : const <dynamic>[])
        if (raw is Map)
          McpToolDefinition.fromJson(Map<String, dynamic>.from(raw)),
    ];
    return McpServerDescription(
      name: serverInfo['name']?.toString() ?? 'MCP Server',
      version: serverInfo['version']?.toString() ?? '?',
      tools: tools.where((tool) => tool.name.isNotEmpty).toList(),
    );
  }

  Future<McpToolResult> callTool({
    required GatewayConnection connection,
    required String name,
    required Map<String, dynamic> arguments,
    CancelToken? cancelToken,
  }) async {
    final result = await _request(
      connection: connection,
      method: 'tools/call',
      params: {'name': name, 'arguments': arguments},
      mcpName: name,
      cancelToken: cancelToken,
    );
    final content = <Map<String, dynamic>>[
      for (final raw in result['content'] is List
          ? result['content'] as List<dynamic>
          : const <dynamic>[])
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];
    final callResult = McpToolResult(
      content: content,
      structuredContent: _stringMap(result['structuredContent']),
      isError: result['isError'] == true,
    );
    if (callResult.isError) {
      throw McpClientException(
        callResult.text.trim().isEmpty
            ? 'MCP 工具 $name 执行失败'
            : callResult.text.trim(),
        code: 'tool_error',
      );
    }
    return callResult;
  }

  Future<Uint8List> readBinaryResource({
    required GatewayConnection connection,
    required String uri,
    CancelToken? cancelToken,
  }) async {
    final result = await _request(
      connection: connection,
      method: 'resources/read',
      params: {'uri': uri},
      mcpName: uri,
      cancelToken: cancelToken,
    );
    final contents = result['contents'];
    if (contents is! List || contents.isEmpty || contents.first is! Map) {
      throw const McpClientException('MCP Resource 没有返回内容');
    }
    final item = Map<String, dynamic>.from(contents.first as Map);
    final blob = item['blob'];
    if (blob is String && blob.isNotEmpty) {
      try {
        return base64Decode(blob);
      } on FormatException catch (error) {
        throw McpClientException('MCP Resource Base64 无效：$error');
      }
    }
    final text = item['text'];
    if (text is String) return Uint8List.fromList(utf8.encode(text));
    throw const McpClientException('MCP Resource 既没有 blob 也没有 text');
  }

  Future<Map<String, dynamic>> _request({
    required GatewayConnection connection,
    required String method,
    required Map<String, dynamic> params,
    String? mcpName,
    CancelToken? cancelToken,
  }) async {
    final config = connection.config;
    if (!config.isConfigured) {
      throw const McpClientException('MCP Server 尚未启用或配置');
    }
    final endpoint = _endpoint(config.normalizedBaseUrl);
    final token = await connection.resolveApiToken();
    final stampedParams = <String, dynamic>{
      ...params,
      '_meta': {
        'io.modelcontextprotocol/protocolVersion': _protocolVersion,
        'io.modelcontextprotocol/clientInfo': {
          'name': 'expert-chat',
          'version': '3.5.0',
        },
        'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{},
      },
    };
    try {
      final response = await _dio.post<Object?>(
        endpoint,
        data: {
          'jsonrpc': '2.0',
          'id': 'expert-chat-${++_nextId}',
          'method': method,
          'params': stampedParams,
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'MCP-Protocol-Version': _protocolVersion,
            'Mcp-Method': method,
            'Mcp-Name': ?mcpName,
            if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          },
          responseType: ResponseType.json,
          connectTimeout: config.requestTimeout,
          receiveTimeout: config.requestTimeout,
          sendTimeout: config.requestTimeout,
          validateStatus: (status) => status != null && status < 500,
        ),
        cancelToken: cancelToken,
      );
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        throw const McpClientException(
          'MCP Server 鉴权失败：请检查 MCP Token',
          code: 'unauthorized',
        );
      }
      final envelope = _responseMap(response.data);
      if (status >= 400) {
        throw McpClientException(
          _rpcErrorMessage(envelope) ?? 'MCP HTTP 请求失败（$status）',
          code: 'http_error',
        );
      }
      final error = envelope['error'];
      if (error is Map) {
        throw McpClientException(
          error['message']?.toString() ?? 'MCP JSON-RPC 请求失败',
          code: error['code']?.toString() ?? 'rpc_error',
        );
      }
      final result = envelope['result'];
      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      throw const McpClientException('MCP Server 返回了无效的 JSON-RPC 结果');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const McpClientException('MCP 请求超时：请检查服务器或增大超时时间');
      }
      if (error.type == DioExceptionType.connectionError) {
        throw const McpClientException('无法连接 MCP Server：请检查地址和网络');
      }
      final envelope = _responseMap(error.response?.data);
      throw McpClientException(
        _rpcErrorMessage(envelope) ?? 'MCP 请求失败：${error.message}',
      );
    }
  }

  static String _endpoint(String baseUrl) {
    final value = baseUrl.trim();
    return value.endsWith('/mcp') ? value : '$value/mcp';
  }

  static Map<String, dynamic> _responseMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const {};
  }

  static String? _rpcErrorMessage(Map<String, dynamic> envelope) {
    final error = envelope['error'];
    if (error is Map && error['message'] != null) {
      return error['message'].toString();
    }
    return null;
  }
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}
