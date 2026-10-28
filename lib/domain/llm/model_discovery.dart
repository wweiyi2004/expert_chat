import 'dart:convert';
import 'package:dio/dio.dart';
import 'llm_provider.dart';
import 'llm_endpoint.dart';
import '../../data/model_token_limits.dart';
import 'auth/chatgpt_network.dart';

/// Safe diagnostics for model-list requests: do not echo headers or response
/// bodies, which can contain credentials or private relay details.
String describeModelDiscoveryError(Object error) {
  if (error is DioException) {
    if (CancelToken.isCancel(error)) return '已取消获取模型列表';
    final status = error.response?.statusCode;
    if (status == 401) return '获取模型列表认证失败（401），请检查 API Key 或重新登录。';
    if (status == 403) return '服务拒绝访问模型列表（403），请检查账号权限。';
    if (status == 404 || status == 405) {
      return '找不到模型列表接口（$status），请检查 API 地址；OpenRouter 应使用 https://openrouter.ai/api/v1。';
    }
    if (status == 429) return '获取模型列表被限流（429），请稍后重试。';
    if (status != null) return '获取模型列表失败（HTTP $status），请稍后重试或检查服务状态。';
    if ({
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
    }.contains(error.type)) {
      return '获取模型列表超时，请检查网络或代理后重试。';
    }
    return '无法连接模型服务，请检查 API 地址、网络或代理。';
  }
  if (error is FormatException) {
    return '模型列表格式无效或分页不完整；原模型列表已保留，请检查 API 地址或手动填写模型 ID。';
  }
  return '未能获取可用模型；原模型列表已保留，可检查 API 地址后重试或手动填写模型 ID。';
}

class ModelDiscovery {
  ModelDiscovery({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
              followRedirects: false,
            ),
          );
  final Dio _dio;
  final Map<String, ModelTokenLimits> limits = {};
  Future<List<String>> scan(LlmConfig config, CancelToken token) async {
    if (config.authMode == 'chatgpt') {
      if (config.baseUrl.replaceFirst(RegExp(r'/+$'), '') !=
          'https://api.openai.com/v1') {
        throw StateError('订阅凭据仅支持官方服务');
      }
      await configureChatGptNetwork(_dio);
    }
    limits.clear();
    final roots = config.apiFormat == LlmApiFormat.auto
        ? LlmEndpoint.roots(config.baseUrl, format: config.effectiveApiFormat)
        : [LlmEndpoint.base(config.baseUrl)];
    Object? lastError;
    for (final root in roots.toSet()) {
      try {
        limits.clear();
        return await _scanRoot(config.copyWith(baseUrl: root), token);
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        lastError = error;
        if (![404, 405].contains(error.response?.statusCode)) rethrow;
      }
    }
    throw lastError ?? StateError('服务没有提供模型列表，可手动填写模型 ID');
  }

  Future<List<String>> _scanRoot(LlmConfig config, CancelToken token) async {
    final format = config.effectiveApiFormat;
    final base = format == LlmApiFormat.geminiNative
        ? config.geminiVersionBaseUrl
        : LlmEndpoint.base(config.baseUrl);
    final headers = <String, String>{
      ...config.transportHeaders,
      if (config.authMode != 'none' && config.apiKey.isNotEmpty)
        if (format == LlmApiFormat.geminiNative)
          'x-goog-api-key': config.apiKey
        else if (format == LlmApiFormat.anthropicMessages &&
            config.authMode != 'kimiCode')
          'x-api-key': config.apiKey
        else
          'Authorization': 'Bearer ${config.apiKey}',
      if (format == LlmApiFormat.anthropicMessages)
        'anthropic-version': '2023-06-01',
    };
    final models = <String>{};
    final visited = <String>{};
    var uri = Uri.parse(LlmEndpoint.action(base, 'models'));
    var query = <String, dynamic>{
      if (format == LlmApiFormat.geminiNative) 'pageSize': 1000,
      if (format == LlmApiFormat.anthropicMessages) 'limit': 1000,
    };
    var pages = 0;
    while (true) {
      if (token.isCancelled) throw token.cancelError!;
      if (++pages > 10000 || !visited.add('$uri|${jsonEncode(query)}')) {
        throw const FormatException('模型分页未完成：游标重复或页数异常，保留原模型列表');
      }
      final response = await _dio.get<dynamic>(
        uri.toString(),
        options: Options(headers: headers),
        cancelToken: token,
        queryParameters: query,
      );
      final raw = response.data;
      final data = raw is List ? <String, dynamic>{'data': raw} : raw;
      if (data is! Map) throw const FormatException('模型列表不是有效 JSON 对象');
      final nested = data['data'];
      final values = nested is Map
          ? nested['data'] ?? nested['models'] ?? nested['items']
          : data['data'] ?? data['models'] ?? data['items'];
      if (values is! List) throw const FormatException('服务未返回模型列表；原目录保持不变');
      for (final entry in values) {
        final rawId = entry is String
            ? entry
            : entry is Map
            ? entry['id'] ?? entry['slug'] ?? entry['name']
            : null;
        final id = rawId
            ?.toString()
            .replaceFirst(RegExp(r'^models/'), '')
            .trim();
        if (id == null || id.isEmpty) continue;
        models.add(id);
        if (entry is Map) {
          final uri = Uri.parse(config.baseUrl);
          final metadata = ModelTokenLimits.fromModelApi(
            entry,
            kimiCode:
                {'api.kimi.com', 'api.kimi.ai'}.contains(uri.host) &&
                uri.path.startsWith('/coding'),
          );
          if (metadata.isKnown) limits[id] = metadata;
        }
      }
      final pagination = data['pagination'] is Map
          ? data['pagination'] as Map
          : nested is Map
          ? nested
          : data;
      final pageToken = data['nextPageToken'] ?? pagination['nextPageToken'];
      final cursor = data['next_cursor'] ?? pagination['next_cursor'];
      final nextPage = data['next_page'] ?? pagination['next_page'];
      final hasMore =
          data['has_more'] == true ||
          pagination['has_more'] == true ||
          pagination['hasMore'] == true;
      final links = data['links'];
      final nextLink = links is Map ? links['next'] : data['next'];
      if (pageToken is String && pageToken.isNotEmpty) {
        query = {...query, 'pageToken': pageToken};
        continue;
      }
      if (cursor is String && cursor.isNotEmpty) {
        query = {...query, 'cursor': cursor};
        continue;
      }
      if (nextPage != null &&
          nextPage != false &&
          nextPage.toString().isNotEmpty &&
          nextPage != 0) {
        query = {...query, 'page': nextPage};
        continue;
      }
      if (nextLink is String && nextLink.isNotEmpty) {
        final next = uri.resolve(nextLink);
        if (next.scheme != uri.scheme ||
            next.host != uri.host ||
            next.port != uri.port ||
            next.userInfo.isNotEmpty ||
            next.path != uri.path) {
          throw const FormatException('模型分页地址异常，未将凭据发送到其他地址；原目录保持不变');
        }
        uri = next;
        query = {};
        continue;
      }
      if (hasMore) {
        final last =
            data['last_id'] ??
            pagination['last_id'] ??
            (values.isNotEmpty && values.last is Map
                ? values.last['id']
                : null);
        if (last == null || last.toString().isEmpty) {
          throw const FormatException('提供商表示还有模型，但没有返回有效分页游标；原目录保持不变');
        }
        query = {...query, 'after_id': last};
        continue;
      }
      final total = pagination['total'] ?? data['total'];
      if (total is num && total > models.length) {
        throw FormatException(
          '仅获取到 ${models.length}/$total 个模型，提供商没有返回下一页；原目录保持不变',
        );
      }
      break;
    }
    if (models.isEmpty) throw StateError('服务未返回可用模型，可手动添加模型 ID');
    return models.toList()..sort();
  }
}
