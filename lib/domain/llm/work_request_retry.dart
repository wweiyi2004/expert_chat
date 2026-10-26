import 'dart:async';
import 'package:dio/dio.dart';
import 'llm_provider.dart';
import 'llm_http_errors.dart';
import 'transport_error_stub.dart'
    if (dart.library.io) 'transport_error_io.dart'
    as transport;

/// Retries only a model request that has produced no public result. Never wraps
/// tool execution. Callers disable this when channel/model fallback is enabled.
class WorkRequestRetry {
  const WorkRequestRetry({this.baseDelay = const Duration(seconds: 1)});
  final Duration baseDelay;
  Stream<ChatChunk> run({
    required Stream<ChatChunk> Function() open,
    required CancelToken token,
    required bool allowed,
    void Function(Map<String, Object?>? retry)? onRetry,
    void Function(int attempt)? onAttempt,
  }) async* {
    try {
      for (var attempt = 1; attempt <= 3; attempt++) {
        if (token.isCancelled) throw token.cancelError!;
        onAttempt?.call(attempt);
        var produced = false;
        try {
          await for (final chunk in open()) {
            if (chunk.contentDelta != null ||
                chunk.reasoningDelta != null ||
                chunk.toolCalls != null ||
                chunk.serverSearchActivity != null ||
                chunk.usage != null ||
                chunk.finishReason != null ||
                chunk.citations != null ||
                chunk.responseOutputItems != null) {
              produced = true;
            }
            yield chunk;
          }
          return;
        } catch (error) {
          final status = error is LlmHttpException
              ? error.statusCode
              : error is DioException
              ? error.response?.statusCode
              : null;
          final denied =
              error is LlmHttpException &&
              {
                'invalid_api_key',
                'authentication_error',
                'permission_error',
                'insufficient_quota',
              }.contains(error.apiCode);
          final transient =
              !denied &&
              ({429, 502, 503, 504}.contains(status) ||
                  error is DioException &&
                      {
                        DioExceptionType.connectionError,
                        DioExceptionType.connectionTimeout,
                      }.contains(error.type));
          if (!allowed ||
              produced ||
              !transient ||
              attempt == 3 ||
              token.isCancelled) {
            rethrow;
          }
          var delay = baseDelay * attempt;
          if (error is DioException) {
            final header = error.response?.headers.value('retry-after');
            final seconds = int.tryParse(header ?? '');
            final date = transport.retryAfterDate(header ?? '');
            final requested = seconds != null
                ? Duration(seconds: seconds)
                : date?.difference(DateTime.now());
            if (requested != null && requested > delay) {
              delay = requested > const Duration(seconds: 30)
                  ? const Duration(seconds: 30)
                  : requested;
            }
          }
          final until = DateTime.now().add(delay);
          onRetry?.call({
            'code': status?.toString() ?? 'connection',
            'message': '请求暂时失败，等待重试',
            'attempt': attempt + 1,
            'max_attempts': 3,
            'retry_at': until.toUtc().toIso8601String(),
            'retry_after_ms': delay.inMilliseconds,
          });
          final gate = Completer<void>();
          final timer = Timer(delay, gate.complete);
          try {
            await Future.any<void>([
              gate.future,
              token.whenCancel.then<void>((e) => throw e),
            ]);
            if (token.isCancelled) throw token.cancelError!;
          } finally {
            timer.cancel();
          }
          onRetry?.call(null);
        }
      }
    } finally {
      onRetry?.call(null);
    }
  }
}
