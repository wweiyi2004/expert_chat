import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../data/models.dart';
import 'llm_provider.dart';

/// OpenAI-compatible `POST /files` client.
///
/// Used for DeepSeek vision: upload a local image once, then send `file_id`
/// instead of repeating a large base64 payload. See
/// https://api-docs.deepseek.com/zh-cn/guides/files_api
class OpenAiCompatibleFilesClient {
  OpenAiCompatibleFilesClient({Dio? dio})
    : _dio =
          dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 30)));

  final Dio _dio;
  final Map<String, String> _cache = {};

  static const _defaultTtlSeconds = 86400;

  /// Rewrites DeepSeek vision messages so `data:` images become Files API ids.
  /// Public `http(s)` URLs stay as `image_url` (docs method 2). Upload failures
  /// fall back to the original data URL so the turn still proceeds.
  Future<List<LlmRequestMessage>> attachFileIds({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    CancelToken? cancelToken,
  }) async {
    if (!config.isOfficialDeepSeek || !config.capabilities.supportsVision) {
      return messages;
    }
    var changed = false;
    final out = <LlmRequestMessage>[];
    for (final message in messages) {
      if (message.role != MessageRole.user || message.imageDataUrls.isEmpty) {
        out.add(message);
        continue;
      }
      final fileIds = [...message.imageFileIds];
      final leftoverUrls = <String>[];
      for (final url in message.imageDataUrls) {
        if (!url.startsWith('data:')) {
          leftoverUrls.add(url);
          continue;
        }
        try {
          final id = await uploadDataUrl(
            config: config,
            dataUrl: url,
            cancelToken: cancelToken,
          );
          fileIds.add(id);
          changed = true;
        } catch (_) {
          leftoverUrls.add(url);
        }
      }
      out.add(
        LlmRequestMessage(
          role: message.role,
          content: message.content,
          reasoningContent: message.reasoningContent,
          toolCallId: message.toolCallId,
          toolCalls: message.toolCalls,
          imageDataUrls: leftoverUrls,
          imageFileIds: fileIds,
          responseOutputItems: message.responseOutputItems,
        ),
      );
    }
    return changed ? out : messages;
  }

  Future<String> uploadDataUrl({
    required LlmConfig config,
    required String dataUrl,
    CancelToken? cancelToken,
  }) async {
    final parsed = parseDataUrl(dataUrl);
    if (parsed == null) {
      throw ArgumentError('invalid data URL');
    }
    return uploadBytes(
      config: config,
      bytes: parsed.bytes,
      filename: parsed.filename,
      mimeType: parsed.mimeType,
      cancelToken: cancelToken,
    );
  }

  Future<String> uploadBytes({
    required LlmConfig config,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
    CancelToken? cancelToken,
  }) async {
    final cacheKey = sha256.convert(bytes).toString();
    final cached = _cache[cacheKey];
    if (cached != null && cached.isNotEmpty) return cached;

    final url = '${config.baseUrl.replaceAll(RegExp(r"/+$"), "")}/files';
    final form = FormData.fromMap({
      'purpose': 'user_data',
      'expires_after[anchor]': 'created_at',
      'expires_after[seconds]': '$_defaultTtlSeconds',
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: DioMediaType.parse(mimeType),
      ),
    });
    final response = await _dio.post<Map<String, dynamic>>(
      url,
      data: form,
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Accept': 'application/json',
        },
      ),
    );
    final id = response.data?['id']?.toString() ?? '';
    if (id.isEmpty) {
      throw StateError('Files API 未返回 file_id');
    }
    _cache[cacheKey] = id;
    return id;
  }

  static ({Uint8List bytes, String mimeType, String filename})? parseDataUrl(
    String dataUrl,
  ) {
    final match = RegExp(
      r'^data:(image/[a-zA-Z0-9.+-]+);base64,(.+)$',
      dotAll: true,
    ).firstMatch(dataUrl.trim());
    if (match == null) return null;
    final mime = match.group(1)!;
    try {
      final bytes = Uint8List.fromList(base64Decode(match.group(2)!));
      if (bytes.isEmpty) return null;
      final ext = switch (mime) {
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
        _ => 'bin',
      };
      return (bytes: bytes, mimeType: mime, filename: 'image.$ext');
    } catch (_) {
      return null;
    }
  }
}
