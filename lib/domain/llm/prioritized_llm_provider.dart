import 'package:dio/dio.dart';
import 'llm_provider.dart';
import 'llm_http_errors.dart';

class PrioritizedLlmProvider implements LlmProvider {
  PrioritizedLlmProvider({
    required this.delegate,
    required this.candidates,
    required this.credentials,
  });
  final LlmProvider delegate;
  final Future<List<LlmConfig>> Function(LlmConfig) candidates;
  final Future<LlmConfig> Function(LlmConfig) credentials;
  final _pinned = <String, LlmConfig>{};
  bool _canTryNext(Object error) {
    final status = error is LlmHttpException
        ? error.statusCode
        : error is DioException
        ? error.response?.statusCode
        : null;
    return [
          401,
          402,
          403,
          404,
          408,
          429,
          500,
          502,
          503,
          504,
        ].contains(status) ||
        error is DioException &&
            error.type == DioExceptionType.connectionTimeout;
  }

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    final key = config.routingSessionId == null
        ? null
        : '${config.routingSessionId}:${config.model}';
    final pinned = key == null ? null : _pinned[key];
    final options = pinned != null ? [pinned] : await candidates(config);
    for (var index = 0; index < options.length; index++) {
      var emitted = false;
      try {
        if (cancelToken?.isCancelled == true) return;
        final selected = (await credentials(options[index])).copyWith(
          responseHeaderTimeout: config.responseHeaderTimeout,
          clearResponseHeaderTimeout: config.responseHeaderTimeout == null,
        );
        await for (final chunk in delegate.streamChat(
          config: selected,
          messages: messages,
          tools: tools,
          thinking: thinking,
          reasoningEffort: reasoningEffort,
          forceToolName: forceToolName,
          cancelToken: cancelToken,
        )) {
          if (!emitted) {
            emitted = true;
            if (key != null) {
              _pinned[key] = selected;
              if (_pinned.length > 256) _pinned.remove(_pinned.keys.first);
            }
            yield ChatChunk(actualConfig: selected);
          }
          yield chunk;
        }
        return;
      } catch (error) {
        // Never move an accepted stream or its tool continuations to another host.
        if (emitted ||
            pinned != null ||
            index == options.length - 1 ||
            !_canTryNext(error) ||
            cancelToken?.isCancelled == true)
          rethrow;
      }
    }
  }
}
