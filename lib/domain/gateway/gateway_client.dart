import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';
import '../mcp/mcp_client.dart';

class GatewayCapabilities {
  const GatewayCapabilities({
    required this.protocolVersion,
    required this.gatewayVersion,
    required this.modules,
    this.tools = const [],
  });

  final int protocolVersion;
  final String gatewayVersion;
  final Map<String, Map<String, dynamic>> modules;
  final List<DiscoveredMcpTool> tools;

  List<String> get ids => modules.keys.toList(growable: false);

  bool supports(String id) => modules.containsKey(id);

  Map<String, dynamic> metadata(String id) => modules[id] ?? const {};
}

class GatewayException implements Exception {
  const GatewayException(this.message, {this.code = 'gateway_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class GatewayClient {
  GatewayClient({Dio? dio}) : _mcp = McpClient(dio: dio);

  final McpClient _mcp;

  Future<GatewayCapabilities> discover({
    required GatewayConnection connection,
    CancelToken? cancelToken,
  }) async {
    final base = connection.config.normalizedBaseUrl;
    if (base.isEmpty) throw const GatewayException('未配置 MCP Server URL');
    try {
      final server = await _mcp.discover(
        connection: connection,
        cancelToken: cancelToken,
      );
      final names = {for (final tool in server.tools) tool.name};
      final modules = <String, Map<String, dynamic>>{
        if (names.contains('edit_document'))
          GatewayCapabilityIds.documentEdit: {
            'transport': 'mcp',
            'tool': 'edit_document',
          },
        if (names.contains('convert_document'))
          GatewayCapabilityIds.documentConvert: {
            'transport': 'mcp',
            'tool': 'convert_document',
          },
      };
      return GatewayCapabilities(
        protocolVersion: 1,
        gatewayVersion: server.version,
        modules: modules,
        tools: [
          for (final tool in server.tools)
            if (tool.name.isNotEmpty)
              DiscoveredMcpTool(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema,
              ),
        ],
      );
    } on McpClientException catch (error) {
      throw GatewayException(error.message, code: error.code);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw GatewayException(_humanize(error));
    }
  }

  static String _humanize(DioException error) {
    final status = error.response?.statusCode;
    final data = error.response?.data;
    String? detail;
    if (data is Map) {
      final raw = data['detail'] ?? data['message'];
      if (raw is String) detail = raw;
      if (raw is Map && raw['error'] is Map) {
        detail = (raw['error'] as Map)['message']?.toString();
      }
    }
    if (status == 401 || status == 403) return 'MCP Token 无效或无权限';
    if (status == 404) return '服务器没有提供 /mcp Endpoint';
    if (status != null) {
      return 'MCP 请求失败（$status）${detail == null ? '' : '：$detail'}';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return 'MCP 连接超时，请检查地址和网络';
    }
    return '无法连接 MCP Server：${error.message ?? error.type.name}';
  }
}
