import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';

// Error bodies are untrusted server input; bound the diagnostic buffer.
const _maxErrorBodyBytes = 64 * 1024;

Future<Exception> humanizeLlmHttpError(
  DioException error, {
  String notFoundMessage = '接口未找到（404）：请检查 Base URL 或模型名是否正确。',
}) async {
  final status = error.response?.statusCode;
  final apiMessage = await _extractApiMessage(error.response?.data);
  final detail = apiMessage == null ? '' : '：$apiMessage';
  if (status == 400) return Exception('请求有误（400）$detail');
  if (status == 401) return Exception('鉴权失败（401）：请检查 API Key 是否正确。');
  if (status == 402) return Exception('额度不足（402）：账户余额不足。');
  if (status == 404) return Exception('$notFoundMessage$detail');
  if (status == 422) return Exception('参数有误（422）$detail');
  if (status == 429) return Exception('请求过于频繁（429）：稍后重试。');
  if (error.type == DioExceptionType.connectionTimeout) {
    return Exception('连接超时：请检查网络或 Base URL。');
  }
  if (error.type == DioExceptionType.receiveTimeout) {
    return Exception('响应超时：服务端长时间没有返回数据，请稍后重试。');
  }
  if (error.type == DioExceptionType.sendTimeout) {
    return Exception('请求发送超时：请检查网络后重试。');
  }
  if (error.type == DioExceptionType.connectionError) {
    return Exception('连接失败：请检查网络或 Base URL。');
  }
  if (error.type == DioExceptionType.badCertificate) {
    return Exception('TLS 证书校验失败：请检查 Base URL 是否可信。');
  }
  if (error.type == DioExceptionType.unknown) {
    return Exception('网络连接中断：请检查网络后重试。');
  }
  if (status != null) return Exception('请求失败（$status）$detail');
  return Exception('请求失败：${error.message ?? error.type.name}');
}

/// Best-effort extraction; a broken error body must preserve the HTTP failure.
Future<String?> _extractApiMessage(dynamic data) async {
  try {
    String? raw;
    if (data is ResponseBody) {
      final bytes = <int>[];
      await for (final chunk in data.stream) {
        final remaining = _maxErrorBodyBytes - bytes.length;
        if (remaining <= 0) break;
        if (chunk.length <= remaining) {
          bytes.addAll(chunk);
        } else {
          bytes.addAll(chunk.take(remaining));
          break;
        }
      }
      raw = utf8.decode(bytes, allowMalformed: true);
    } else if (data is String) {
      raw = data;
    } else if (data is Map) {
      return _messageFromMap(data);
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return _messageFromMap(decoded);
    } catch (_) {
      // Non-JSON error pages are shown as bounded text.
    }
    final trimmed = raw.trim();
    return trimmed.length > 200 ? '${trimmed.characters.take(200)}…' : trimmed;
  } catch (_) {
    return null;
  }
}

String? _messageFromMap(Map<dynamic, dynamic> map) {
  final error = map['error'];
  if (error is Map && error['message'] is String) {
    return clipLlmErrorMessage(error['message'] as String);
  }
  if (error is String) return clipLlmErrorMessage(error);
  if (map['message'] is String) {
    return clipLlmErrorMessage(map['message'] as String);
  }
  return null;
}

String clipLlmErrorMessage(String value) {
  final trimmed = value.trim();
  return trimmed.characters.length > 200
      ? '${trimmed.characters.take(200)}…'
      : trimmed;
}
