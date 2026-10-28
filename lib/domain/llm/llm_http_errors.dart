import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import '../errors/app_failure.dart' show redactDiagnostics;
import 'transport_error_stub.dart'
    if (dart.library.io) 'transport_error_io.dart'
    as transport;

// Error bodies are untrusted server input; bound the diagnostic buffer.
const _maxErrorBodyBytes = 64 * 1024;

LlmHttpException llmResponseTimeout(
  Duration limit, {
  bool headers = true,
}) => LlmHttpException(
  '响应超时：服务端在 ${limit.inSeconds} 秒内${headers ? '没有开始返回数据' : '没有返回流式数据'}，请检查网络或稍后重试。',
  diagnostic:
      '阶段：${headers ? '等待响应头' : '流式输出空闲'}\n等待上限：${limit.inMilliseconds} ms',
);

/// Retains machine-readable HTTP status while preserving existing UI messages.
class LlmHttpException implements Exception {
  const LlmHttpException(
    this.message, {
    this.statusCode,
    this.apiMessage,
    this.apiCode,
    this.diagnostic,
    this.category,
    this.retryAfterSeconds,
  });
  final String message;
  final int? statusCode;
  final String? apiMessage;
  final String? apiCode;

  /// Stable diagnostic category; quota/auth failures must not be retried as load.
  final String? category;
  final int? retryAfterSeconds;

  /// Client-generated metadata only; excludes API response bodies and inputs.
  final String? diagnostic;

  bool get isProtocolRejection {
    final detail = (apiMessage ?? '').toLowerCase();
    if ({
      'model_not_found',
      'invalid_api_key',
      'authentication_error',
      'permission_error',
      'insufficient_quota',
    }.contains(apiCode)) {
      return false;
    }
    // A missing model, invalid credentials or quota is not an endpoint probe.
    if (RegExp(
      r'model.{0,80}(not found|not exist|not available|unknown)|unknown model|model_not_found|模型.*(不存在|不可用)',
    ).hasMatch(detail)) {
      return false;
    }
    if ({404, 405, 415, 501}.contains(statusCode)) return true;
    if (statusCode != 400 && statusCode != 422) return false;
    // Only explicit top-level schema/endpoint mismatches. Never retry generic
    // 400s (context length, invalid tool/image arguments, unsupported thinking).
    return RegExp(
      r'''(?:input|messages|contents|max_tokens|anthropic-version)["'` ]*[: ]+(?:is )?(?:required|missing|field required)|(?:missing|required)[^\n]{0,35}["'`](?:input|messages|contents|max_tokens|anthropic-version)["'`]|(?:unsupported|unknown|invalid) (?:api |request )?(?:protocol|endpoint)|(?:endpoint|protocol)[^\n]{0,60}(?:not supported|unsupported)|not supported[^\n]{0,80}/(?:v1/)?(?:chat/completions|responses|messages)''',
    ).hasMatch(detail);
  }

  @override
  String toString() =>
      'Exception: $message${statusCode == null && diagnostic != null ? '\n$diagnostic' : ''}';
}

Future<Exception> humanizeLlmHttpError(
  DioException error, {
  String notFoundMessage = '接口未找到（404）：请检查 Base URL 或模型名是否正确。',
  String authMode = 'apiKey',
}) async {
  final status = error.response?.statusCode;
  final diagnostics = redactDiagnostics(
    [
      '请求错误类型：${error.type.name}',
      if (error.requestOptions.uri.host.isNotEmpty)
        '服务：${error.requestOptions.uri.host}',
      if (status != null) 'HTTP $status',
      transport.underlyingTransportDetails(error.error),
    ].join('\n'),
    secrets: [
      for (final header in error.requestOptions.headers.entries)
        if (RegExp(
          'authorization|api.?key|token',
          caseSensitive: false,
        ).hasMatch(header.key))
          header.value.toString().replaceFirst(
            RegExp(r'^Bearer\s+', caseSensitive: false),
            '',
          ),
    ],
  );
  String? apiCode;
  final rawApiMessage = await _extractApiMessage(
    error.response?.data,
    onCode: (code) => apiCode = code,
  );
  final secrets = [
    for (final header in error.requestOptions.headers.entries)
      if (RegExp(
        'authorization|api.?key|token',
        caseSensitive: false,
      ).hasMatch(header.key))
        header.value.toString().replaceFirst(
          RegExp(r'^Bearer\s+', caseSensitive: false),
          '',
        ),
  ];
  final apiMessage = rawApiMessage == null
      ? null
      : redactDiagnostics(rawApiMessage, secrets: secrets);
  if (apiCode != null) apiCode = redactDiagnostics(apiCode!, secrets: secrets);
  final rawRetry = error.response?.headers.value('retry-after');
  final retryAfter = int.tryParse(rawRetry ?? '');
  LlmHttpException failure(String message, [String? category]) =>
      LlmHttpException(
        message,
        statusCode: status,
        apiMessage: apiMessage,
        apiCode: apiCode,
        diagnostic: diagnostics,
        category: category,
        retryAfterSeconds: retryAfter,
      );
  final detail = apiMessage == null ? '' : '：$apiMessage';
  final codeAndMessage = '${apiCode ?? ''} ${apiMessage ?? ''}'.toLowerCase();
  final oauth = authMode == 'chatgpt' || authMode == 'kimiCode';
  final quota = RegExp(
    r'insufficient[_ ]quota|quota.{0,35}(exhaust|exceed|deplet)|usage[_ ]limit|reached.{0,40}(weekly|monthly|usage|quota)|weekly.{0,30}limit|monthly.{0,30}limit|credit.{0,20}(exhaust|insufficient)|额度.{0,20}(不足|耗尽|用尽|超)|用量.{0,15}(上限|耗尽)|套餐.{0,15}(用尽|超出)',
  ).hasMatch(codeAndMessage);
  final expiredPlan = RegExp(
    r'(subscription|membership|plan).{0,25}(expired|inactive)|套餐.{0,15}(过期|到期)|会员.{0,15}(过期|到期)',
  ).hasMatch(codeAndMessage);
  final balance = RegExp(
    r'insufficient[_ ](balance|credit|funds)|balance.{0,20}(insufficient|low|exhaust)|余额不足|欠费',
  ).hasMatch(codeAndMessage);
  if (expiredPlan) {
    return failure(
      '订阅已到期或未激活：请在 /login 查看此账号的套餐，并前往官方控制台处理。$detail',
      'subscription_expired',
    );
  }
  if (quota) {
    return failure(
      '套餐额度已用尽：请在 /login 查看余量和重置时间；可手动选择其他账号，立即重试不会恢复额度。$detail',
      'quota_exhausted',
    );
  }
  if (status == 402 || balance) {
    return failure('账户余额或付费额度不足：请核对官方账单及套餐状态。$detail', 'balance_exhausted');
  }
  if (status == 401) {
    return failure(
      oauth
          ? '账号授权失效或被撤销（401）：请在 /login 选择此账号并重新登录。'
          : 'API Key 无效、已过期或已撤销（401）：请在 /login 管理此来源并更新 Key。',
      'authentication',
    );
  }
  if (status == 403) {
    return failure('账号无权使用此模型或接口（403）：请核对套餐权益、模型和接入地址。$detail', 'permission');
  }
  if (status == 400 || status == 422) {
    if (RegExp(
      r'context[_ ]length|maximum context|too many tokens|context.{0,20}(exceed|limit)|上下文.{0,15}(超|长)',
    ).hasMatch(codeAndMessage)) {
      return failure(
        '上下文超过模型限制：用 /context 减少发送内容，或用 /compact 压缩历史。$detail',
        'context_length',
      );
    }
    if (RegExp(
      r'assistant.{0,30}(empty|must not)|tool.{0,30}(call|result|id).{0,30}(missing|invalid)|reasoning.{0,30}(required|missing)',
    ).hasMatch(codeAndMessage)) {
      return failure(
        '消息格式与当前模型不兼容（$status）：请保留会话并检查该来源的协议设置。$detail',
        'message_format',
      );
    }
    return failure('请求参数有误（$status）$detail', 'invalid_request');
  }
  if (status == 404) return failure('$notFoundMessage$detail');
  if (status == 429) {
    return failure(
      '服务限流（429）：${retryAfter != null && retryAfter > 0 ? '约 $retryAfter 秒后再试' : '请降低并发并稍后重试'}；若持续发生，请查看该账号的套餐额度。$detail',
      'rate_limit',
    );
  }
  if (error.type == DioExceptionType.connectionTimeout) {
    return failure('连接超时：请检查网络或 Base URL。');
  }
  if (error.type == DioExceptionType.receiveTimeout) {
    return failure('响应超时：服务端长时间没有返回数据，请稍后重试。');
  }
  if (error.type == DioExceptionType.sendTimeout) {
    return failure('请求发送超时：请检查网络后重试。');
  }
  if (error.type == DioExceptionType.connectionError) {
    return failure('连接失败：请检查网络或 Base URL。');
  }
  if (error.type == DioExceptionType.badCertificate) {
    return failure('TLS 证书校验失败：请检查 Base URL 是否可信。');
  }
  if (error.type == DioExceptionType.unknown) {
    return transport.isTransportFailure(error.error)
        ? failure('网络连接中断：请检查网络后重试。')
        : failure('请求处理异常：请查看技术信息中的底层异常类型，不能据此认定网络中断。');
  }
  if (status != null) return failure('请求失败（$status）$detail');
  return failure(
    '请求失败：${redactDiagnostics(error.message ?? error.type.name, secrets: secrets)}',
  );
}

/// Best-effort extraction; a broken error body must preserve the HTTP failure.
Future<String?> _extractApiMessage(
  dynamic data, {
  void Function(String?)? onCode,
}) async {
  try {
    String? raw;
    if (data is ResponseBody) {
      final bytes = <int>[];
      await for (final chunk in data.stream.timeout(
        const Duration(seconds: 5),
      )) {
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
      return _messageFromMap(data, onCode: onCode);
    }
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return _messageFromMap(decoded, onCode: onCode);
    } catch (_) {
      // Non-JSON error pages are shown as bounded text.
    }
    final trimmed = raw.trim();
    return trimmed.length > 200 ? '${trimmed.characters.take(200)}…' : trimmed;
  } catch (_) {
    return null;
  }
}

String? _messageFromMap(
  Map<dynamic, dynamic> map, {
  void Function(String?)? onCode,
}) {
  final error = map['error'];
  final topCode = map['code'] ?? map['type'];
  if (topCode is String) onCode?.call(topCode);
  if (error is Map) {
    final code = error['code'] ?? error['type'];
    if (code is String) onCode?.call(code);
  }
  if (error is Map && error['message'] is String) {
    return clipLlmErrorMessage(error['message'] as String);
  }
  if (error is String) return clipLlmErrorMessage(error);
  if (map['message'] is String) {
    return clipLlmErrorMessage(map['message'] as String);
  }
  final detail = map['detail'];
  if (detail is String) return clipLlmErrorMessage(detail);
  if (detail is List) {
    final fields = <String>[];
    for (final e in detail.take(4)) {
      if (e is! Map || e['loc'] is! List || e['msg'] is! String) continue;
      final loc = e['loc'] as List;
      if (loc.length == 2 && loc.first == 'body') {
        fields.add('${loc.last}: ${e['msg']}');
      }
    }
    if (fields.isNotEmpty) return clipLlmErrorMessage(fields.join('; '));
  }
  return null;
}

String clipLlmErrorMessage(String value) {
  final trimmed = value.trim();
  return trimmed.characters.length > 200
      ? '${trimmed.characters.take(200)}…'
      : trimmed;
}
