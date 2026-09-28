import 'dart:async';

import 'package:dio/dio.dart';

enum FailureKind {
  authentication,
  permission,
  model,
  quota,
  rateLimit,
  network,
  serviceUnavailable,
  timeout,
  storage,
  invalidData,
  cancelled,
  unknown,
}

/// User copy and diagnostic data are separate so a server response never
/// becomes the primary instruction shown to someone trying to recover.
class AppFailure {
  const AppFailure(this.kind, this.title, this.message, this.details);
  final FailureKind kind;
  final String title;
  final String message;
  final String details;

  bool get needsConfiguration => const {
    FailureKind.authentication,
    FailureKind.permission,
    FailureKind.model,
  }.contains(kind);

  factory AppFailure.from(Object error, {Iterable<String> secrets = const []}) {
    final raw = error.toString();
    final text = raw.toLowerCase();
    final dio = error is DioException ? error : null;
    final status = dio?.response?.statusCode;
    bool hasStatus(int code) =>
        status == code ||
        RegExp(
          '(?:HTTP\\s*|[（(])$code(?:[）)]|\\b)',
          caseSensitive: false,
        ).hasMatch(raw);
    final diagnostic = redactDiagnostics(
      dio == null
          ? raw
          : [
              '网络错误：${dio.type.name}',
              if (status != null) 'HTTP $status',
              '服务：${dio.requestOptions.uri.replace(userInfo: '', query: '', fragment: '')}',
            ].join('\n'),
      secrets: secrets,
    );
    AppFailure failure(FailureKind kind, String title, String message) =>
        AppFailure(kind, title, message, diagnostic);
    if (dio?.type == DioExceptionType.cancel || text.contains('已取消')) {
      return failure(
        FailureKind.cancelled,
        '已停止本地等待',
        '可以修改输入后重新尝试；远端是否已经停止需要以服务商记录为准。',
      );
    }
    if (text.contains('填写 api key')) {
      return failure(
        FailureKind.authentication,
        '还未连接模型',
        '请先填写服务信息并验证连接。你的输入仍然保留。',
      );
    }
    if (hasStatus(401) ||
        text.contains('invalid_api_key') ||
        text.contains('unauthorized') ||
        text.contains('鉴权失败')) {
      return failure(
        FailureKind.authentication,
        '密钥未通过验证',
        '请检查 API Key 是否填写完整，并确认它属于当前选择的服务商。',
      );
    }
    if (hasStatus(403) || text.contains('permission_denied')) {
      return failure(
        FailureKind.permission,
        '当前账户没有访问权限',
        '请确认服务商账户已开通所选模型，并检查密钥的使用权限。',
      );
    }
    if (hasStatus(402) ||
        text.contains('insufficient_quota') ||
        text.contains('余额不足')) {
      return failure(FailureKind.quota, '服务商额度不足', '请在服务商账户中检查余额或配额，处理后再重试。');
    }
    if (hasStatus(404) ||
        text.contains('model_not_found') ||
        text.contains('模型不存在')) {
      return failure(
        FailureKind.model,
        '服务地址或模型不可用',
        '请核对服务地址和模型名称，并确认账户可以使用该模型。',
      );
    }
    if (hasStatus(429) || text.contains('rate_limit')) {
      return failure(FailureKind.rateLimit, '请求过于频繁', '请稍等片刻再重试，避免连续提交相同请求。');
    }
    if ((status != null && status >= 500 && status < 600) ||
        RegExp(
          r'(?:HTTP\s*|[（(])5\d\d(?:[）)]|\b)',
          caseSensitive: false,
        ).hasMatch(raw)) {
      return failure(
        FailureKind.serviceUnavailable,
        '服务暂时不可用',
        '请稍后重试，或联系服务维护者检查服务器和上游连接。',
      );
    }
    if (error is TimeoutException ||
        const [
          DioExceptionType.connectionTimeout,
          DioExceptionType.sendTimeout,
          DioExceptionType.receiveTimeout,
        ].contains(dio?.type) ||
        text.contains('超时') ||
        text.contains('timed out')) {
      return failure(
        FailureKind.timeout,
        '等待服务响应超时',
        '请检查网络或稍后重试。如果正在生成图片或处理文档，请先查看已有结果，避免重复提交。',
      );
    }
    if (const [
          DioExceptionType.connectionError,
          DioExceptionType.badCertificate,
        ].contains(dio?.type) ||
        text.contains('socketexception') ||
        text.contains('连接失败') ||
        text.contains('网络连接中断') ||
        text.contains('证书')) {
      return failure(
        FailureKind.network,
        '暂时无法连接服务',
        '请检查网络、代理和服务地址；连接恢复后可以重试。',
      );
    }
    if (text.contains('sqlite') ||
        text.contains('filesystemexception') ||
        text.contains('磁盘') ||
        text.contains('本地保存失败')) {
      return failure(
        FailureKind.storage,
        '本地数据暂时无法读写',
        '请检查存储空间和文件访问权限。保留应用数据，处理后再试。',
      );
    }
    final cleaned = diagnostic
        .replaceFirst(
          RegExp(r'^(?:Exception|FormatException|Bad state):\s*'),
          '',
        )
        .split('\n')
        .first;
    final readable =
        RegExp(r'[\u4e00-\u9fff]').hasMatch(raw) &&
        !cleaned.contains('DioException');
    return failure(
      error is FormatException ? FailureKind.invalidData : FailureKind.unknown,
      '操作未完成',
      readable
          ? (cleaned.length > 240 ? '${cleaned.substring(0, 240)}…' : cleaned)
          : '暂时无法完成此操作。请稍后重试；技术信息可用于排查问题。',
    );
  }
}

String redactDiagnostics(String value, {Iterable<String> secrets = const []}) {
  var safe = value;
  final known = secrets.where((s) => s.trim().isNotEmpty).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final secret in known) {
    safe = safe.replaceAll(secret, '[已隐藏]');
  }
  safe = safe.replaceAll(
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [已隐藏]',
  );
  safe = safe.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]+'), '[已隐藏]');
  safe = safe.replaceAllMapped(
    RegExp(
      r'''((?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|authorization|password|secret)["']?\s*[:=]\s*)["']?[^\s,"'&}\]]+''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[已隐藏]',
  );
  safe = safe.replaceAllMapped(RegExp(r'''https?://[^\s<>"']+'''), (m) {
    final uri = Uri.tryParse(m[0]!);
    return uri == null
        ? '[服务地址]'
        : uri.replace(userInfo: '', query: '', fragment: '').toString();
  });
  safe = safe.replaceAll(
    RegExp(r'''(?<![A-Za-z0-9])[A-Za-z]:[\\/][^\r\n"'<>|]*'''),
    '[本地路径]',
  );
  safe = safe.replaceAll(RegExp(r'''\\\\[^\\\s]+\\[^\r\n"'<>|]*'''), '[本地路径]');
  safe = safe.replaceAll(
    RegExp(
      r'''/(?:Users|home|data/user|storage/emulated|private|tmp)/[^\r\n"'<>|]*''',
    ),
    '[本地路径]',
  );
  return safe.length > 4000 ? '${safe.substring(0, 4000)}\n…' : safe;
}
