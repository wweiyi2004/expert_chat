import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';

/// Configuration for a single LLM endpoint. Kept provider-agnostic so any
/// OpenAI-compatible service (DeepSeek, Kimi, OpenAI, 智谱…) can be plugged in
/// by only changing [baseUrl] / [model].
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    ModelCapabilities? capabilities,
    // A public param feeding a private backing field (the getter falls back to
    // resolve()); an initializing formal can't keep the public name here.
    // ignore: prefer_initializing_formals
  }) : _capabilities = capabilities;

  /// Base URL WITHOUT the trailing `/chat/completions`, e.g.
  /// `https://api.deepseek.com`.
  final String baseUrl;
  final String apiKey;
  final String model;

  /// Explicit capability override. When null (the default), capabilities are
  /// derived from [model] by [ModelCapabilities.resolve] — the single source of
  /// truth — so callers needn't pass anything for the common case.
  final ModelCapabilities? _capabilities;

  ModelCapabilities get capabilities =>
      _capabilities ?? ModelCapabilities.resolve(model);

  bool get isReady => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  LlmConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    ModelCapabilities? capabilities,
  }) => LlmConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    // Keep an explicit override only if one was set; otherwise stay null so a
    // changed [model] re-derives its own capabilities.
    capabilities: capabilities ?? _capabilities,
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

  Map<String, dynamic> toOpenAiJson() {
    final function = <String, dynamic>{'arguments': argumentsJson};
    if (name != null && name!.isNotEmpty) function['name'] = name;
    return {
      if (id != null && id!.isNotEmpty) 'id': id,
      'type': 'function',
      'function': function,
    };
  }
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

/// One request message sent to an OpenAI-compatible chat endpoint. This is
/// separate from the persisted [ChatMessage] so tool-call protocol messages
/// can stay transient and never clutter the visible conversation history.
class LlmRequestMessage {
  const LlmRequestMessage({
    required this.role,
    required this.content,
    this.reasoningContent,
    this.toolCallId,
    this.toolCalls = const [],
    this.imageDataUrls = const [],
  });

  factory LlmRequestMessage.fromChatMessage(ChatMessage message) =>
      LlmRequestMessage(role: message.role, content: message.content);

  final MessageRole role;
  final String content;
  final String? reasoningContent;
  final String? toolCallId;
  final List<ToolCall> toolCalls;

  /// `data:` image URLs sent alongside [content] to a vision model. When
  /// non-empty, `content` is serialized as an OpenAI multimodal parts array.
  final List<String> imageDataUrls;

  Map<String, dynamic> toOpenAiJson() {
    final json = <String, dynamic>{
      'role': role.wire,
      'content': imageDataUrls.isEmpty
          ? content
          : [
              if (content.isNotEmpty) {'type': 'text', 'text': content},
              for (final url in imageDataUrls)
                {
                  'type': 'image_url',
                  'image_url': {'url': url},
                },
            ],
    };
    if (reasoningContent != null && reasoningContent!.isNotEmpty) {
      json['reasoning_content'] = reasoningContent;
    }
    if (toolCallId != null && toolCallId!.isNotEmpty) {
      json['tool_call_id'] = toolCallId;
    }
    if (toolCalls.isNotEmpty) {
      json['tool_calls'] = toolCalls.map((t) => t.toOpenAiJson()).toList();
    }
    return json;
  }
}

/// Abstraction over a chat LLM backend. Implementations turn a request into a
/// stream of incremental [ChatChunk]s. [tools] enables function calling (M5);
/// when null/empty the request is a plain chat completion (backward compatible).
abstract class LlmProvider {
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    // DeepSeek V4 thinking-mode toggle. null = omit the field (use provider
    // default / non-DeepSeek providers); true/false = enable/disable.
    bool? thinking,
    // Cancels the in-flight HTTP request when the user presses stop, including
    // during connection setup (before any chunk has streamed).
    CancelToken? cancelToken,
  });
}

/// What a given model can do, used to shape the request (which optional
/// fields/params are safe to send) and the UI (the reasoning panel). Resolved
/// from the model id in [resolve] — the ONE place that encodes provider-specific
/// heuristics — but can also be supplied explicitly on [LlmConfig] to override.
class ModelCapabilities {
  const ModelCapabilities({
    required this.isReasoner,
    required this.supportsTools,
    required this.sendThinkingField,
    required this.supportsVision,
    this.supportsReasoningEffort = false,
    this.reasoningCanBeDisabled = false,
  });

  /// Streams a separate `reasoning_content` field (drives the thinking panel).
  final bool isReasoner;

  /// Accepts OpenAI `tools` / function-calling params without erroring.
  final bool supportsTools;

  /// Understands DeepSeek's `{'thinking': {'type': ...}}` toggle field. Only
  /// DeepSeek V4 models do; sending it to other providers risks a 400.
  final bool sendThinkingField;

  /// Accepts OpenAI's `reasoning_effort` request field.
  final bool supportsReasoningEffort;

  /// Accepts `reasoning_effort: none`; always-reasoning models omit the field
  /// in normal mode and use their provider default instead.
  final bool reasoningCanBeDisabled;

  /// Accepts image content parts (`image_url`) — i.e. is a vision model. When
  /// false, image attachments are described in text rather than sent.
  final bool supportsVision;

  /// Best-effort capability detection from a model id. Heuristic, but kept in a
  /// single place so adding a provider/model means editing only here. Mirrors
  /// the previous scattered `KnownModels` checks exactly.
  factory ModelCapabilities.resolve(String model) {
    // Aggregator gateways expose ids as vendor/model (qwen/qwen3-max,
    // deepseek-ai/deepseek-v4); capabilities depend on the model segment only.
    final m = model.toLowerCase().split('/').last;
    final nonReasoning = m.contains('non-reasoning');
    final grok43 =
        m == 'grok-4.3' || m.startsWith('grok-4.3-') || m == 'grok-4.3-latest';
    final grok45 =
        m == 'grok-4.5' || m.startsWith('grok-4.5-') || m == 'grok-4.5-latest';

    // Broadened vs. the old check to also catch `*-thinking-*` reasoners (e.g.
    // kimi-thinking-preview, GLM thinking variants), which previously did not
    // light up the panel. xAI Grok: `grok-*-reasoning` / mini reasoning paths.
    final reasoner =
        m.contains('reasoner') ||
        (m.contains('reasoning') && !nonReasoning) ||
        m.contains('thinking') ||
        m.contains('v4-pro') ||
        m.startsWith('o1') ||
        m.startsWith('o3') ||
        m.startsWith('o4') ||
        m.contains('-r1') ||
        m.endsWith('r1') ||
        grok45 ||
        m.startsWith('grok-4.20-multi-agent') ||
        // Grok mini often used as the "think" model in dual-model setups.
        (m.startsWith('grok') && m.contains('mini') && !nonReasoning);

    // DeepSeek V4 supports tools in both thinking and non-thinking modes;
    // older/legacy reasoner endpoints (deepseek-reasoner, o1, *reasoning*)
    // reject tool-call parameters. Grok OpenAI-compatible endpoints accept tools
    // on the main chat models. Unknown model ids default to false: adding
    // `tools` to an otherwise compatible endpoint can turn a normal URL-bearing
    // message into a 400 response, while the controller has deterministic
    // pre-search/pre-fetch fallbacks when tools are unavailable.
    bool tools;
    if (m.startsWith('deepseek-v4') ||
        m == 'deepseek-chat' ||
        m.startsWith('grok') ||
        m.startsWith('gpt-') ||
        m.startsWith('chatgpt-') ||
        m.startsWith('o3') ||
        m.startsWith('o4') ||
        m.startsWith('moonshot-') ||
        m.startsWith('kimi-') ||
        m.startsWith('glm-') ||
        m.startsWith('qwen') ||
        m.startsWith('minimax') ||
        m.startsWith('doubao') ||
        m.startsWith('hunyuan') ||
        m.startsWith('gemini-') ||
        m.startsWith('claude-') ||
        m.startsWith('mistral-')) {
      tools = true;
    } else if (m == 'deepseek-reasoner' ||
        m.startsWith('o1') ||
        m.contains('reasoner') ||
        (m.contains('reasoning') && !m.startsWith('grok'))) {
      tools = false;
    } else {
      tools = false;
    }

    // Well-known OpenAI-compatible vision models. Conservative: unknown models
    // default to no vision so images are never sent to a text-only endpoint.
    final vision =
        m.contains('vision') ||
        m.contains('-vl') ||
        m.contains('vl-') ||
        m.contains('4o') || // gpt-4o / gpt-4o-mini
        m.contains('gpt-4.1') ||
        m.contains('gpt-4-turbo') ||
        m.contains('glm-4v') ||
        m.contains('4.5v') ||
        m.contains('gemini') ||
        m.contains('claude-3') ||
        m.contains('claude-4') ||
        m.contains('pixtral') ||
        m.contains('llava') ||
        m.contains('internvl') ||
        (m.startsWith('grok') &&
            (m.contains('vision') ||
                (m.startsWith('grok-4.') && !m.contains('build'))));

    return ModelCapabilities(
      isReasoner: reasoner,
      supportsTools: tools,
      // DeepSeek-only request body field — never send to xAI/OpenAI/etc.
      sendThinkingField: m.startsWith('deepseek-v4'),
      supportsVision: vision,
      supportsReasoningEffort: grok43 || grok45,
      reasoningCanBeDisabled: grok43,
    );
  }
}

/// Known models surfaced in pickers and presets. Capability checks delegate to
/// [ModelCapabilities] so there is a single source of truth; these thin helpers
/// remain for call sites (e.g. the model picker) that only hold a model id.
class KnownModels {
  static const chat = 'deepseek-v4-flash';
  static const reasoner = 'deepseek-v4-pro';

  static const all = <String>[chat, reasoner];

  static bool isReasoner(String model) =>
      ModelCapabilities.resolve(model).isReasoner;

  static bool supportsToolCalls(String model) =>
      ModelCapabilities.resolve(model).supportsTools;
}
