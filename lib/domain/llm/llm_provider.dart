import '../../data/models.dart';

/// Configuration for a single LLM endpoint. Kept provider-agnostic so any
/// OpenAI-compatible service (DeepSeek, Kimi, OpenAI, 智谱…) can be plugged in
/// by only changing [baseUrl] / [model].
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  /// Base URL WITHOUT the trailing `/chat/completions`, e.g.
  /// `https://api.deepseek.com`.
  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isReady => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  LlmConfig copyWith({String? baseUrl, String? apiKey, String? model}) =>
      LlmConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );
}

/// One tool the model may call, described in OpenAI function-calling format.
/// Carried through to the request body verbatim under `tools` (M5).
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// JSON-Schema object describing the function arguments.
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// A tool call requested by the model in the stream (M5). Deltas with the same
/// [index] are concatenated by the caller to assemble [argumentsJson].
class ToolCall {
  const ToolCall({
    required this.index,
    this.id,
    this.name,
    this.argumentsJson = '',
  });

  final int index;
  final String? id;
  final String? name;
  final String argumentsJson;
}

/// A single streamed delta from the model. Any field may be null/empty for a
/// given chunk. [reasoningDelta] carries the chain-of-thought emitted by
/// reasoning models such as `deepseek-reasoner`; [toolCalls] carries
/// function-call deltas; [finishReason] is set on the terminal chunk.
class ChatChunk {
  const ChatChunk({
    this.contentDelta,
    this.reasoningDelta,
    this.toolCalls,
    this.finishReason,
  });

  final String? contentDelta;
  final String? reasoningDelta;
  final List<ToolCall>? toolCalls;
  final String? finishReason;
}

/// Abstraction over a chat LLM backend. Implementations turn a request into a
/// stream of incremental [ChatChunk]s. [tools] enables function calling (M5);
/// when null/empty the request is a plain chat completion (backward compatible).
abstract class LlmProvider {
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<ChatMessage> messages,
    List<ToolSpec>? tools,
    // DeepSeek V4 thinking-mode toggle. null = omit the field (use provider
    // default / non-DeepSeek providers); true/false = enable/disable.
    bool? thinking,
  });
}

/// Known models surfaced in pickers and presets. The reasoner detection is
/// heuristic so custom/third-party reasoning models still light up the panel.
class KnownModels {
  static const chat = 'deepseek-v4-flash';
  static const reasoner = 'deepseek-v4-pro';

  static const all = <String>[chat, reasoner];

  /// Reasoner models stream a separate `reasoning_content` field and do NOT
  /// support function calling.
  static bool isReasoner(String model) =>
      model.contains('reasoner') ||
      model.contains('reasoning') ||
      model.contains('v4-pro') ||
      model.startsWith('o1') ||
      model.startsWith('o3') ||
      model.contains('-r1') ||
      model.endsWith('r1');
}
