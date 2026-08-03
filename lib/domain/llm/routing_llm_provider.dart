import 'package:dio/dio.dart' show CancelToken;

import 'llm_provider.dart';
import 'openai_compatible_provider.dart';
import 'responses_api_provider.dart';

/// Routes each request to Chat Completions or the Responses API.
///
/// Responses is used only when [LlmConfig.useServerWebSearch] is true
/// (provider-hosted `web_search`). Everything else stays on the battle-tested
/// Chat Completions path so non-DeepSeek endpoints keep working unchanged.
class RoutingLlmProvider implements LlmProvider {
  RoutingLlmProvider({
    OpenAiCompatibleProvider? chatCompletions,
    ResponsesApiProvider? responses,
  }) : _chat = chatCompletions ?? OpenAiCompatibleProvider(),
       _responses = responses ?? ResponsesApiProvider();

  final OpenAiCompatibleProvider _chat;
  final ResponsesApiProvider _responses;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    // Forced client tools (e.g. edit_document) need Chat Completions
    // tool_choice; keep off the Responses path for those turns.
    final forceClientTool = forceToolName != null && forceToolName.trim().isNotEmpty;
    if (config.useServerWebSearch && !forceClientTool) {
      return _responses.streamChat(
        config: config,
        messages: messages,
        tools: tools,
        thinking: thinking,
        forceToolName: forceToolName,
        cancelToken: cancelToken,
      );
    }
    return _chat.streamChat(
      config: config,
      messages: messages,
      tools: tools,
      thinking: thinking,
      forceToolName: forceToolName,
      cancelToken: cancelToken,
    );
  }
}
