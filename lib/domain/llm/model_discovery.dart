import 'package:dio/dio.dart';
import 'llm_provider.dart';
import 'llm_endpoint.dart';
import '../../data/model_token_limits.dart';
import 'auth/chatgpt_network.dart';

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
    if (config.authMode == 'chatgpt') await configureChatGptNetwork(_dio);
    limits.clear();
    final roots = config.apiFormat == LlmApiFormat.auto
        ? LlmEndpoint.roots(config.baseUrl, format: config.effectiveApiFormat)
        : [LlmEndpoint.base(config.baseUrl)];
    Object? lastError;
    for (final root in roots.toSet()) {
      try {
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
      if (config.authMode != 'none' && config.apiKey.isNotEmpty)
        if (format == LlmApiFormat.geminiNative)
          'x-goog-api-key': config.apiKey
        else if (format == LlmApiFormat.anthropicMessages)
          'x-api-key': config.apiKey
        else
          'Authorization': 'Bearer ${config.apiKey}',
      if (format == LlmApiFormat.anthropicMessages)
        'anthropic-version': '2023-06-01',
    };
    final models = <String>{};
    final cursors = <String>{};
    String? cursor;
    do {
      final response = await _dio.get<dynamic>(
        '$base/models',
        options: Options(headers: headers),
        cancelToken: token,
        queryParameters: {
          format == LlmApiFormat.geminiNative ? 'pageToken' : 'after_id':
              ?cursor,
        },
      );
      final data = response.data;
      if (data is! Map) throw const FormatException('模型列表不是有效 JSON 对象');
      final values = data['data'] ?? data['models'];
      if (values is! List) {
        throw const FormatException('服务未返回 models 或 data 模型列表');
      }
      for (final entry in values) {
        if (entry is! Map) continue;
        if (entry['visibility'] != null && entry['visibility'] != 'list') {
          continue;
        }
        final methods = entry['supportedGenerationMethods'];
        if (methods is List && !methods.contains('generateContent')) continue;
        final id = (entry['id'] ?? entry['slug'] ?? entry['name'])
            ?.toString()
            .replaceFirst(RegExp(r'^models/'), '');
        if (id != null && id.isNotEmpty) {
          models.add(id);
          final metadata = ModelTokenLimits.fromModelApi(entry);
          if (metadata.isKnown) limits[id] = metadata;
        }
      }
      cursor =
          (data['nextPageToken'] ??
                  (data['has_more'] == true ? data['last_id'] : null))
              as String?;
    } while (cursor != null && cursor.isNotEmpty && cursors.add(cursor));
    if (models.isEmpty) throw StateError('服务未返回可用模型，可手动添加模型 ID');
    return models.toList()..sort();
  }
}
