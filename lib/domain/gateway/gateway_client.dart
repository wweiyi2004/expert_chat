import 'package:dio/dio.dart';

import '../../data/gateway_config.dart';

class GatewayCapabilities {
  const GatewayCapabilities({
    required this.protocolVersion,
    required this.gatewayVersion,
    required this.modules,
  });

  final int protocolVersion;
  final String gatewayVersion;
  final Map<String, Map<String, dynamic>> modules;

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
  GatewayClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<GatewayCapabilities> discover({
    required GatewayConnection connection,
    CancelToken? cancelToken,
  }) async {
    final base = connection.config.normalizedBaseUrl;
    if (base.isEmpty) throw const GatewayException('未配置 Gateway Base URL');
    try {
      final headers = await _headers(connection);
      final response = await _dio.get<Map<String, dynamic>>(
        '$base/v1/capabilities',
        options: Options(
          headers: headers,
          receiveTimeout: connection.config.requestTimeout,
          sendTimeout: connection.config.requestTimeout,
        ),
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data == null) throw const GatewayException('Gateway 返回了空能力清单');
      final protocolVersion = (data['protocol_version'] as num?)?.toInt() ?? 0;
      if (protocolVersion != 1) {
        throw GatewayException('不支持的 Gateway 协议版本：$protocolVersion');
      }
      final rawModules = data['capabilities'];
      if (rawModules is! Map) {
        throw const GatewayException('Gateway 能力清单格式无效');
      }
      final modules = <String, Map<String, dynamic>>{};
      for (final entry in rawModules.entries) {
        final id = entry.key.toString().trim();
        if (id.isEmpty) continue;
        final metadata = entry.value;
        modules[id] = metadata is Map
            ? Map<String, dynamic>.from(metadata)
            : <String, dynamic>{};
      }
      return GatewayCapabilities(
        protocolVersion: protocolVersion,
        gatewayVersion: data['gateway_version']?.toString() ?? '?',
        modules: modules,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw GatewayException(_humanize(error));
    }
  }

  static Future<Map<String, String>> _headers(
    GatewayConnection connection,
  ) async {
    final token = await connection.resolveApiToken();
    return {if (token.isNotEmpty) 'Authorization': 'Bearer $token'};
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
    if (status == 401 || status == 403) return 'Gateway Token 无效或无权限';
    if (status == 404) return '服务器不是兼容的 Expert Chat Gateway（缺少能力发现接口）';
    if (status != null) {
      return 'Gateway 请求失败（$status）${detail == null ? '' : '：$detail'}';
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return 'Gateway 连接超时，请检查地址和网络';
    }
    return '无法连接 Gateway：${error.message ?? error.type.name}';
  }
}
