import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../data/media_api_config.dart';

class GeneratedImage {
  const GeneratedImage({
    this.base64,
    this.remoteUrl,
    this.mimeType = 'image/png',
    this.revisedPrompt,
  });

  final String? base64;
  final String? remoteUrl;
  final String mimeType;
  final String? revisedPrompt;
}

/// Optional OpenAI-compatible image-generation and text-to-speech endpoints.
///
/// Vision chat itself keeps using [LlmProvider], because it is the same
/// `/chat/completions` protocol with multimodal message parts.
class OpenAiCompatibleMediaProvider {
  OpenAiCompatibleMediaProvider({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 3),
              sendTimeout: const Duration(minutes: 1),
            ),
          );

  final Dio _dio;

  static const int _maxAudioBytes = 25 * 1024 * 1024;
  static const int _maxBase64Chars = 32 * 1024 * 1024;

  Future<GeneratedImage> generateImage({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    CancelToken? cancelToken,
  }) async {
    _ensureConfigured(config, apiKey, '生图');
    final response = await _postJson(
      _endpoint(config.baseUrl, 'images/generations'),
      apiKey: apiKey,
      body: {
        'model': config.model.trim(),
        'prompt': prompt.trim(),
        if (config.imageSize.trim().isNotEmpty) 'size': config.imageSize.trim(),
      },
      cancelToken: cancelToken,
    );

    final data = response['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const FormatException('生图接口没有返回图片数据。');
    }
    final item = Map<String, dynamic>.from(data.first as Map);
    final revisedPrompt = item['revised_prompt'] as String?;
    final rawBase64 = item['b64_json'] as String?;
    if (rawBase64 != null && rawBase64.isNotEmpty) {
      final parsed = _parseBase64Image(rawBase64);
      return GeneratedImage(
        base64: parsed.$2,
        mimeType: parsed.$1,
        revisedPrompt: revisedPrompt,
      );
    }

    final rawUrl = item['url'] as String?;
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const FormatException('生图接口返回了无效的图片地址。');
    }
    return GeneratedImage(
      remoteUrl: uri.toString(),
      revisedPrompt: revisedPrompt,
    );
  }

  Future<Uint8List> synthesizeSpeech({
    required MediaApiConfig config,
    required String apiKey,
    required String text,
    CancelToken? cancelToken,
  }) async {
    _ensureConfigured(config, apiKey, 'TTS');
    try {
      final response = await _dio.post<List<int>>(
        _endpoint(config.baseUrl, 'audio/speech'),
        data: jsonEncode({
          'model': config.model.trim(),
          'input': text.trim(),
          'voice': config.voice.trim().isEmpty ? 'alloy' : config.voice.trim(),
          'response_format': 'mp3',
        }),
        options: Options(
          responseType: ResponseType.bytes,
          headers: _headers(apiKey, accept: 'audio/mpeg'),
        ),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (received > _maxAudioBytes) {
            cancelToken?.cancel('TTS 音频超过 25 MB 限制');
          }
        },
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) throw const FormatException('TTS 接口返回了空音频。');
      if (bytes.length > _maxAudioBytes) {
        throw const FormatException('TTS 音频超过 25 MB 限制。');
      }
      return Uint8List.fromList(bytes);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, '语音生成');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required String apiKey,
    required Map<String, dynamic> body,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        url,
        data: jsonEncode(body),
        options: Options(headers: _headers(apiKey)),
        cancelToken: cancelToken,
      );
      final raw = response.data;
      if (raw is Map) return Map<String, dynamic>.from(raw);
      if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
      throw const FormatException('接口返回了无法识别的数据格式。');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, '生图');
    }
  }

  Map<String, String> _headers(
    String apiKey, {
    String accept = 'application/json',
  }) => {
    'Authorization': 'Bearer ${apiKey.trim()}',
    'Content-Type': 'application/json',
    'Accept': accept,
  };

  String _endpoint(String baseUrl, String path) {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.endsWith('/$path')) return base;
    return '$base/$path';
  }

  void _ensureConfigured(
    MediaApiConfig config,
    String apiKey,
    String capability,
  ) {
    if (!config.isConfiguredWith(apiKey)) {
      throw StateError('$capability API 尚未完整配置。');
    }
    final uri = Uri.tryParse(config.baseUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw FormatException('$capability Base URL 无效。');
    }
  }

  (String, String) _parseBase64Image(String raw) {
    var mimeType = 'image/png';
    var payload = raw.trim();
    if (payload.startsWith('data:')) {
      final comma = payload.indexOf(',');
      final header = comma < 0 ? '' : payload.substring(5, comma);
      if (comma < 0 || !header.endsWith(';base64')) {
        throw const FormatException('生图接口返回了无效的 data URL。');
      }
      final candidate = header.substring(0, header.length - 7);
      if (candidate.startsWith('image/')) mimeType = candidate;
      payload = payload.substring(comma + 1);
    }
    // Some gateways wrap long payloads in newlines; Dart's decoder rejects
    // any whitespace, so strip it before validating.
    if (payload.contains(RegExp(r'\s'))) {
      payload = payload.replaceAll(RegExp(r'\s'), '');
    }
    if (payload.length > _maxBase64Chars) {
      throw const FormatException('生成图片超过 24 MB 限制。');
    }
    // Shape validation instead of a full decode: decoding up to 32M chars
    // would allocate ~24 MB on the caller's isolate only to be discarded.
    if (payload.isEmpty ||
        payload.length % 4 == 1 ||
        !RegExp(r'^[A-Za-z0-9+/\-_]+={0,2}$').hasMatch(payload)) {
      throw const FormatException('生图接口返回了无效的 Base64 图片。');
    }
    final padded = payload.endsWith('=') || payload.length % 4 == 0
        ? payload
        : payload.padRight(
            payload.length + (4 - payload.length % 4),
            '=',
          );
    return (mimeType, padded);
  }

  Future<Exception> _humanizeError(DioException e, String action) async {
    final status = e.response?.statusCode;
    final detail = _errorMessage(e.response?.data);
    final suffix = detail == null ? '' : '：$detail';
    if (status == 401) return Exception('$action鉴权失败（401）：请检查 API Key。');
    if (status == 404) {
      return Exception('$action接口未找到（404）：请检查 Base URL。$suffix');
    }
    if (status == 429) return Exception('$action请求过于频繁（429），请稍后重试。');
    if (status != null) return Exception('$action失败（$status）$suffix');
    if (e.type == DioExceptionType.connectionTimeout) {
      return Exception('$action连接超时：请检查网络或 Base URL。');
    }
    return Exception('$action失败：${e.message ?? e.type.name}');
  }

  String? _errorMessage(dynamic raw) {
    try {
      if (raw is String) raw = jsonDecode(raw);
      if (raw is! Map) return null;
      final error = raw['error'];
      final value = error is Map
          ? error['message'] ?? error['detail']
          : error ?? raw['message'];
      if (value is! String || value.trim().isEmpty) return null;
      final trimmed = value.trim();
      return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
    } catch (_) {
      return null;
    }
  }
}
