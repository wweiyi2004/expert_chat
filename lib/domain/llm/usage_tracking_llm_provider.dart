import 'package:dio/dio.dart' show CancelToken;

import 'llm_provider.dart';

typedef LlmUsageRecorder = void Function(LlmConfig config, LlmUsage usage);

/// Decorates any LLM provider and records its terminal usage chunk without
/// changing the stream semantics seen by callers.
class UsageTrackingLlmProvider implements LlmProvider {
  UsageTrackingLlmProvider({required this.delegate, required this.onUsage});

  final LlmProvider delegate;
  final LlmUsageRecorder onUsage;

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
    LlmUsage? finalUsage;
    await for (final chunk in delegate.streamChat(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      forceToolName: forceToolName,
      cancelToken: cancelToken,
    )) {
      final usage = chunk.usage;
      if (usage != null) finalUsage = usage;
      yield chunk;
    }
    if (finalUsage != null) onUsage(config, finalUsage);
  }
}
