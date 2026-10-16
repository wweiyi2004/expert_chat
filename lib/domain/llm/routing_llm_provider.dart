import 'package:dio/dio.dart' show CancelToken;

import 'gemini_native_provider.dart';
import 'llm_provider.dart';
import 'openai_compatible_files_client.dart';
import 'openai_compatible_provider.dart';
import 'responses_api_provider.dart';

/// Routes each request to Chat Completions, the Responses API, or Gemini native.
///
/// Responses is used only when [LlmConfig.useServerWebSearch] is true
/// (provider-hosted `web_search`). Gemini native is used when
/// [LlmConfig.isGeminiNative] is true. Everything else stays on the
/// battle-tested Chat Completions path.
class RoutingLlmProvider implements LlmProvider {
  RoutingLlmProvider({
    OpenAiCompatibleProvider? chatCompletions,
    ResponsesApiProvider? responses,
    GeminiNativeProvider? geminiNative,
    OpenAiCompatibleFilesClient? files,
  }) : _chat = chatCompletions ?? OpenAiCompatibleProvider(),
       _responses = responses ?? ResponsesApiProvider(),
       _gemini = geminiNative ?? GeminiNativeProvider(),
       _files = files ?? OpenAiCompatibleFilesClient();

  final OpenAiCompatibleProvider _chat;
  final ResponsesApiProvider _responses;
  final GeminiNativeProvider _gemini;
  final OpenAiCompatibleFilesClient _files;

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
    if (config.isGeminiNative) {
      yield* _gemini.streamChat(
        config: config,
        messages: messages,
        tools: tools,
        thinking: thinking,
        reasoningEffort: reasoningEffort,
        forceToolName: forceToolName,
        cancelToken: cancelToken,
      );
      return;
    }
    final resolved = await _files.attachFileIds(
      config: config,
      messages: messages,
      cancelToken: cancelToken,
    );
    final stream = config.useServerWebSearch
        ? _responses.streamChat(
            config: config,
            messages: resolved,
            tools: tools,
            thinking: thinking,
            reasoningEffort: reasoningEffort,
            forceToolName: forceToolName,
            cancelToken: cancelToken,
          )
        : _chat.streamChat(
            config: config,
            messages: resolved,
            tools: tools,
            thinking: thinking,
            reasoningEffort: reasoningEffort,
            forceToolName: forceToolName,
            cancelToken: cancelToken,
          );
    yield* stream;
  }
}
