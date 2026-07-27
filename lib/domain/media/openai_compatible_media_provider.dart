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

  /// Text-to-image (`/images/generations`) or image-to-image (`/images/edits`)
  /// when [referenceImageBytes] is provided (OpenAI-compatible multipart).
  Future<GeneratedImage> generateImage({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    CancelToken? cancelToken,
    List<int>? referenceImageBytes,
    String referenceMimeType = 'image/png',
    String referenceFileName = 'reference.png',
  }) async {
    _ensureConfigured(config, apiKey, '生图');
    final ref = referenceImageBytes;
    if (ref != null && ref.isNotEmpty) {
      return _editImage(
        config: config,
        apiKey: apiKey,
        prompt: prompt,
        imageBytes: ref,
        mimeType: referenceMimeType,
        fileName: referenceFileName,
        cancelToken: cancelToken,
      );
    }

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
    return _parseGeneratedImageResponse(response, cancelToken: cancelToken);
  }

  /// OpenAI-compatible image edit / img2img via multipart `images/edits`.
  Future<GeneratedImage> _editImage({
    required MediaApiConfig config,
    required String apiKey,
    required String prompt,
    required List<int> imageBytes,
    required String mimeType,
    required String fileName,
    CancelToken? cancelToken,
  }) async {
    if (imageBytes.length > 20 * 1024 * 1024) {
      throw const FormatException('参考图超过 20 MB 限制。');
    }
    // Prefer an extension that matches the mime so gateways sniff correctly.
    var safeName = fileName.trim().isEmpty ? 'reference.png' : fileName.trim();
    final mime = mimeType.trim().isEmpty || !mimeType.startsWith('image/')
        ? 'image/png'
        : mimeType.trim();
    if (!safeName.contains('.')) {
      final ext = switch (mime) {
        'image/jpeg' || 'image/jpg' => 'jpg',
        'image/webp' => 'webp',
        'image/gif' => 'gif',
        _ => 'png',
      };
      safeName = '$safeName.$ext';
    }
    final form = FormData.fromMap({
      'model': config.model.trim(),
      'prompt': prompt.trim(),
      if (config.imageSize.trim().isNotEmpty) 'size': config.imageSize.trim(),
      // Without an explicit contentType Dio sends application/octet-stream,
      // which several OpenAI-compatible gateways reject as "invalid image".
      'image': MultipartFile.fromBytes(
        imageBytes,
        filename: safeName,
        contentType: _mediaTypeOf(mime),
      ),
    });

    try {
      final response = await _dio.post<dynamic>(
        _endpoint(config.baseUrl, 'images/edits'),
        data: form,
        options: Options(
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Accept': 'application/json',
            // Let Dio set multipart boundary; do not force application/json.
          },
        ),
        cancelToken: cancelToken,
      );
      final raw = response.data;
      Map<String, dynamic> map;
      if (raw is Map) {
        map = Map<String, dynamic>.from(raw);
      } else if (raw is String) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw const FormatException('图生图接口返回了无法识别的数据格式。');
        }
        map = Map<String, dynamic>.from(decoded);
      } else {
        throw const FormatException('图生图接口返回了无法识别的数据格式。');
      }
      return _parseGeneratedImageResponse(map, cancelToken: cancelToken);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw await _humanizeError(e, '图生图');
    }
  }

  Future<GeneratedImage> _parseGeneratedImageResponse(
    Map<String, dynamic> response, {
    CancelToken? cancelToken,
  }) async {
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
    // Embed bytes so the chat bubble does not depend on a short-lived CDN URL
    // (common with edits/generations gateways). If the download fails we fail
    // loudly instead of storing a URL that will 404 later - a silent "success"
    // that vanishes on reload is worse than a retryable error.
    try {
      final downloaded = await _dio.get<List<int>>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
        cancelToken: cancelToken,
      );
      final bytes = downloaded.data;
      if (bytes != null && bytes.isNotEmpty && bytes.length <= 20 * 1024 * 1024) {
        return GeneratedImage(
          base64: base64Encode(bytes),
          mimeType: _mimeFromUrlOrBytes(uri.toString(), bytes),
          remoteUrl: uri.toString(),
          revisedPrompt: revisedPrompt,
        );
      }
      throw const FormatException('图片已生成，但返回数据为空或过大，请重试。');
    } on FormatException {
      rethrow;
    } on DioException catch (e) {
      // Preserve cancellation semantics so the controller can tell a user
      // cancel apart from a real download failure.
      if (CancelToken.isCancel(e)) rethrow;
      throw const FormatException('图片已生成，但下载图片数据失败，请重试。');
    } catch (_) {
      throw const FormatException('图片已生成，但下载图片数据失败，请重试。');
    }
  }

  /// `image/…` is already guaranteed by the caller, but a malformed subtype
  /// (`image/`, `image/x y`) would make [DioMediaType.parse] throw mid-upload.
  DioMediaType _mediaTypeOf(String mime) {
    try {
      return DioMediaType.parse(mime);
    } on FormatException {
      return DioMediaType('image', 'png');
    }
  }

  String _mimeFromUrlOrBytes(String url, List<int> bytes) {
    final lower = url.toLowerCase();
    if (lower.contains('.jpg') || lower.contains('.jpeg')) return 'image/jpeg';
    if (lower.contains('.webp')) return 'image/webp';
    if (lower.contains('.gif')) return 'image/gif';
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    return 'image/png';
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
      // Accept both ";base64" and bare data URLs some gateways emit.
      if (comma < 0) {
        throw const FormatException('生图接口返回了无效的 data URL。');
      }
      final candidate = header.split(';').first;
      if (candidate.startsWith('image/')) mimeType = candidate;
      payload = payload.substring(comma + 1);
    }
    if (payload.length > _maxBase64Chars) {
      throw const FormatException('生成图片超过 24 MB 限制。');
    }
    // Clean + validate in one linear scan (see [_normalizeBase64]) instead of
    // a full decode: decoding up to 32M chars would allocate ~24 MB on the
    // caller's isolate only to be discarded.
    final normalized = _normalizeBase64(payload);
    if (normalized == null) {
      throw const FormatException('生图接口返回了无效的 Base64 图片。');
    }
    final pad = (4 - normalized.length % 4) % 4;
    final padded = pad == 0
        ? normalized
        : normalized.padRight(normalized.length + pad, '=');
    return (mimeType, padded);
  }

  /// Strip whitespace, map the URL-safe alphabet to the standard one and
  /// validate the payload in a single O(n) pass. Returns the unpadded payload,
  /// or null when it is not base64 at all.
  ///
  /// Deliberately hand-rolled rather than `RegExp(r'^[A-Za-z0-9+/]+={0,2}$')`:
  /// an anchored greedy loop keeps per-character backtrack state, and measured
  /// on this SDK it blows the regexp backtrack stack at exactly 4 MiB of base64
  /// - i.e. any generated image over 3 MiB, which most 1024px+ PNGs are. The
  /// resulting StackOverflowError reached the chat error banner as the bare
  /// text "Stack Overflow" and made img2img - which almost always comes back as
  /// `b64_json` rather than a URL - fail every single time.
  static String? _normalizeBase64(String payload) {
    if (payload.isEmpty) return null;
    var padding = 0; // trailing '=' count
    var stripped = 0; // whitespace dropped
    var rewritten = 0; // '-' / '_' mapped to '+' / '/'
    for (var i = 0; i < payload.length; i++) {
      final c = payload.codeUnitAt(i);
      // Standard alphabet: A-Z a-z 0-9 + /
      if ((c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39) ||
          c == 0x2B ||
          c == 0x2F) {
        if (padding > 0) return null; // data after padding
        continue;
      }
      if (c == 0x3D) {
        // '=' — only ever 1-2 of them, at the very end.
        if (++padding > 2) return null;
        continue;
      }
      if (c == 0x2D || c == 0x5F) {
        // URL-safe '-' / '_'; base64Decode only accepts the standard alphabet.
        if (padding > 0) return null;
        rewritten++;
        continue;
      }
      if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        // Gateways wrap long payloads at 64/76 columns.
        stripped++;
        continue;
      }
      return null;
    }
    final length = payload.length - padding - stripped;
    // A base64 quantum is 2-4 chars; a remainder of 1 can never be valid.
    if (length == 0 || length % 4 == 1) return null;
    if (stripped == 0 && rewritten == 0) {
      return padding == 0 ? payload : payload.substring(0, length);
    }
    // Slow path only when the gateway wrapped or URL-encoded the payload.
    final out = Uint8List(length);
    var n = 0;
    for (var i = 0; i < payload.length; i++) {
      final c = payload.codeUnitAt(i);
      if (c == 0x3D || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) {
        continue;
      }
      out[n++] = c == 0x2D
          ? 0x2B
          : c == 0x5F
          ? 0x2F
          : c;
    }
    return String.fromCharCodes(out);
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
