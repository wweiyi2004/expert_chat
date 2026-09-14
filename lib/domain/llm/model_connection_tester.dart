import 'dart:async';

import 'package:dio/dio.dart';

import '../../data/models.dart';
import 'llm_provider.dart';

class ModelConnectionTester {
  const ModelConnectionTester(
    this.provider, {
    this.timeout = const Duration(seconds: 20),
  });
  final LlmProvider provider;
  final Duration timeout;

  /// A real, short chat probe verifies model access, not just a /models list.
  /// It contains no history, attachments, memory, search or tools.
  Future<Duration> check(
    LlmConfig config, {
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final done = Completer<Duration>();
    final clock = Stopwatch()..start();
    final timer = Timer(timeout, () {
      if (done.isCompleted) return;
      done.completeError(TimeoutException('连接测试超过 ${timeout.inSeconds} 秒'));
      cancelToken.cancel('connection check timeout');
    });
    StreamSubscription<ChatChunk>? subscription;
    unawaited(
      cancelToken.whenCancel.then((error) {
        if (!done.isCompleted) done.completeError(error);
      }),
    );
    try {
      try {
        subscription = provider
            .streamChat(
              config: config.copyWith(
                serverWebSearch: false,
                forceServerWebSearch: false,
                allowReasoningRetry: false,
              ),
              messages: [
                LlmRequestMessage(
                  role: MessageRole.user,
                  content: '连接测试。请仅回复 OK。',
                ),
              ],
              thinking: false,
              cancelToken: cancelToken,
            )
            .listen(
              (chunk) {
                if (!done.isCompleted &&
                    (chunk.contentDelta?.trim().isNotEmpty ?? false)) {
                  done.complete(clock.elapsed);
                }
              },
              onError: (Object error) {
                if (!done.isCompleted) done.completeError(error);
              },
              onDone: () {
                if (!done.isCompleted) {
                  done.completeError(
                    const FormatException('服务已响应，但没有返回可用正文。请检查模型是否支持对话。'),
                  );
                }
              },
            );
      } catch (error, stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      }
      return await done.future;
    } finally {
      timer.cancel();
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('connection check finished');
      }
      if (subscription != null) unawaited(subscription.cancel());
    }
  }
}
