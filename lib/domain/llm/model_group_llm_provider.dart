import 'package:dio/dio.dart';
import '../../data/models.dart';
import 'llm_provider.dart';
import 'llm_http_errors.dart';
import 'model_credentials_unavailable.dart';

/// Explicit model fallback groups wrap same-model channel routing. Never retry
/// a partial stream, tool continuation, cancellation or an arbitrary failure.
class ModelGroupLlmProvider implements LlmProvider {
  const ModelGroupLlmProvider(this.delegate);
  final LlmProvider delegate;
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
    final options = [config, ...config.modelFallbacks];
    for (var index = 0; index < options.length; index++) {
      var accepted = false;
      try {
        if (cancelToken?.isCancelled == true) return;
        final selected = options[index].copyWith(modelFallbacks: const []);
        await for (final chunk in delegate.streamChat(
          config: selected,
          messages: messages,
          tools: tools,
          thinking: thinking,
          reasoningEffort: reasoningEffort,
          forceToolName: forceToolName,
          cancelToken: cancelToken,
        )) {
          accepted = true;
          yield chunk;
        }
        return;
      } catch (error) {
        final status = error is LlmHttpException
            ? error.statusCode
            : error is DioException
            ? error.response?.statusCode
            : null;
        final continuation = messages.any(
          (m) =>
              m.role.wire == 'tool' ||
              m.toolCalls.isNotEmpty ||
              m.responseOutputItems.isNotEmpty,
        );
        if (accepted ||
            continuation ||
            cancelToken?.isCancelled == true ||
            index == options.length - 1 ||
            !(error is ModelCredentialsUnavailable ||
                {402, 404, 408, 429, 500, 502, 503, 504}.contains(status))) {
          rethrow;
        }
      }
    }
  }
}
