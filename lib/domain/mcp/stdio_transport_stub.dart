import 'package:dio/dio.dart';
import '../../data/mcp_process_config.dart';

class StdioTransport {
  StdioTransport(this.config);
  final McpProcessConfig config;
  bool get isAlive => false;
  bool get isClosed => true;
  Map<String, dynamic> get serverInfo => const {};
  Future<void> initialize({
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 30),
  }) async => throw UnsupportedError('本地 MCP 需要 Windows、macOS 或 Linux 桌面版本');
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 30),
  }) async => throw UnsupportedError('此平台不支持本地 MCP');
  Future<void> close() async {}
}
