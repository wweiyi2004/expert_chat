import 'package:dio/dio.dart' show CancelToken;

import '../../data/models.dart';
import 'model_catalog.dart';

export 'model_catalog.dart';

/// Configuration for an OpenAI-compatible or Gemini native LLM endpoint.
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.apiFormat = LlmApiFormat.auto,
    ModelCapabilities? capabilities,
    this.serverWebSearch = false,
    this.forceServerWebSearch = false,
    this.allowReasoningRetry = true,
    // A public param feeding a private backing field (the getter falls back to
    // resolve()); an initializing formal can't keep the public name here.
    // ignore: prefer_initializing_formals
  }) : _capabilities = capabilities;

  /// Base URL WITHOUT the trailing `/chat/completions`, e.g.
  /// `https://api.deepseek.com` or `https://generativelanguage.googleapis.com/v1beta`.
  final String baseUrl;
  final String apiKey;
  final String model;
  final LlmApiFormat apiFormat;

  /// Explicit capability override. When null (the default), capabilities are
  /// derived from [model] by [ModelCapabilities.resolve] — the single source of
  /// truth — so callers needn't pass anything for the common case.
  final ModelCapabilities? _capabilities;

  /// Prefer the provider's Responses API + hosted `web_search` when the model
  /// advertises [ModelCapabilities.supportsServerWebSearch].
  final bool serverWebSearch;

  /// When [serverWebSearch] is on, force `tool_choice: web_search` (联网·强制).
  final bool forceServerWebSearch;

  /// Client-only: the task runner's final attempt must not recursively retry.
  final bool allowReasoningRetry;

  ModelCapabilities get capabilities =>
      _capabilities ?? ModelCapabilities.resolve(model);

  /// Concrete wire format ([LlmApiFormat.openAiCompatible] or
  /// [LlmApiFormat.geminiNative]) after resolving [LlmApiFormat.auto].
  LlmApiFormat get effectiveApiFormat =>
      GeminiEndpoint.resolveFormat(format: apiFormat, baseUrl: baseUrl);

  bool get isGeminiNative => effectiveApiFormat == LlmApiFormat.geminiNative;

  /// Base URL normalized for OpenAI-compatible requests (converts bare Google
  /// Gemini URLs to `/v1beta/openai` when OpenAI-compatible mode is active).
  String get openAiCompatibleBaseUrl =>
      GeminiEndpoint.normalizeOpenAiBaseUrl(baseUrl);

  /// Base URL normalized to the Gemini version root (e.g. `.../v1beta`).
  String get geminiVersionBaseUrl =>
      GeminiEndpoint.normalizeGeminiVersionBaseUrl(baseUrl);

  bool get isReady => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// Official DeepSeek API (Files API + V4 thinking fields live here).
  bool get isOfficialDeepSeek =>
      ModelCatalog.isOfficialDeepSeekEndpoint(baseUrl);

  bool get isDeepSeek =>
      ModelCatalog.isDeepSeek(baseUrl: baseUrl, model: model);

  /// True when this request should hit Responses with server-side search.
  bool get useServerWebSearch =>
      !isGeminiNative &&
      serverWebSearch &&
      capabilities.supportsServerWebSearch;

  LlmConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    LlmApiFormat? apiFormat,
    ModelCapabilities? capabilities,
    bool? serverWebSearch,
    bool? forceServerWebSearch,
    bool? allowReasoningRetry,
  }) => LlmConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    apiFormat: apiFormat ?? this.apiFormat,
    // Keep an explicit override only if one was set; otherwise stay null so a
    // changed [model] re-derives its own capabilities.
    capabilities: capabilities ?? _capabilities,
    serverWebSearch: serverWebSearch ?? this.serverWebSearch,
    forceServerWebSearch: forceServerWebSearch ?? this.forceServerWebSearch,
    allowReasoningRetry: allowReasoningRetry ?? this.allowReasoningRetry,
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

/// Accumulates streamed [ToolCall] deltas that share one `index` into a
/// complete call (ids/names arrive once, argument JSON arrives in fragments).
/// Used by every consumer that drives a function-calling loop.
class ToolCallDraft {
  ToolCallDraft(this.index);

  final int index;
  String? id;
  String? name;
  final StringBuffer _arguments = StringBuffer();

  void merge(ToolCall call) {
    id ??= call.id;
    name ??= call.name;
    if (call.argumentsJson.isNotEmpty) _arguments.write(call.argumentsJson);
  }

  ToolCall build() => ToolCall(
    index: index,
    id: id ?? 'call_${index}_${DateTime.now().microsecondsSinceEpoch}',
    name: name,
    argumentsJson: _arguments.toString(),
  );

  /// Builds the drafts into ordered calls, dropping nameless fragments.
  static List<ToolCall> finalize(Map<int, ToolCallDraft> drafts) {
    final calls = drafts.values.map((d) => d.build()).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return calls.where((c) => (c.name ?? '').isNotEmpty).toList();
  }
}

/// Token usage reported by an LLM provider after a request completes.
///
/// Providers use different names for the same counters, so the wire-specific
/// parsers live here and expose one provider-neutral shape to the rest of the
/// app. Cached input tokens are a subset of [inputTokens].
class LlmUsage {
  const LlmUsage({
    required this.inputTokens,
    required this.outputTokens,
    this.cachedInputTokens = 0,
    this.reasoningTokens = 0,
  });

  final int inputTokens;

  /// Generated tokens, including [reasoningTokens] when reported separately.
  final int outputTokens;
  final int cachedInputTokens;
  final int reasoningTokens;

  bool get hasValues =>
      inputTokens > 0 ||
      outputTokens > 0 ||
      cachedInputTokens > 0 ||
      reasoningTokens > 0;

  static LlmUsage? fromChatCompletions(dynamic raw) {
    if (raw is! Map) return null;
    final input = _readInt(raw['prompt_tokens']);
    final output = _readInt(raw['completion_tokens']);
    final promptDetails = raw['prompt_tokens_details'];
    final completionDetails = raw['completion_tokens_details'];
    final cached = promptDetails is Map
        ? _readInt(promptDetails['cached_tokens'])
        : 0;
    final reasoning = completionDetails is Map
        ? _readInt(completionDetails['reasoning_tokens'])
        : 0;
    final usage = LlmUsage(
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: cached,
      reasoningTokens: reasoning,
    );
    return usage.hasValues || raw.containsKey('total_tokens') ? usage : null;
  }

  static LlmUsage? fromResponses(dynamic raw) {
    if (raw is! Map) return null;
    final input = _readInt(raw['input_tokens']);
    final output = _readInt(raw['output_tokens']);
    final inputDetails = raw['input_tokens_details'];
    final outputDetails = raw['output_tokens_details'];
    final cached = inputDetails is Map
        ? _readInt(inputDetails['cached_tokens'])
        : 0;
    final reasoning = outputDetails is Map
        ? _readInt(outputDetails['reasoning_tokens'])
        : 0;
    final usage = LlmUsage(
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: cached,
      reasoningTokens: reasoning,
    );
    return usage.hasValues || raw.containsKey('total_tokens') ? usage : null;
  }

  static LlmUsage? fromGemini(dynamic raw) {
    if (raw is! Map) return null;
    final input =
        _readInt(raw['promptTokenCount']) +
        _readInt(raw['toolUsePromptTokenCount']);
    final cached = _readInt(raw['cachedContentTokenCount']);
    final reasoning = _readInt(raw['thoughtsTokenCount']);
    final output = _readInt(raw['candidatesTokenCount']) + reasoning;
    final usage = LlmUsage(
      inputTokens: input,
      outputTokens: output,
      cachedInputTokens: cached,
      reasoningTokens: reasoning,
    );
    return usage.hasValues || raw.containsKey('totalTokenCount') ? usage : null;
  }

  static int _readInt(dynamic value) {
    if (value is num) return value.toInt().clamp(0, 1 << 31).toInt();
    return int.tryParse(value?.toString() ?? '')?.clamp(0, 1 << 31).toInt() ??
        0;
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
    this.serverSearchActivity,
    this.citations,
    this.responseOutputItems,
    this.usage,
  });

  final String? contentDelta;
  final String? reasoningDelta;
  final List<ToolCall>? toolCalls;
  final String? finishReason;

  /// Live progress for a provider-hosted `web_search` (Responses API).
  final SearchActivity? serverSearchActivity;

  /// Citations extracted from Responses annotations / search actions.
  final List<Citation>? citations;

  /// Native model payload for this request: Responses `output` items or
  /// Gemini `parts` (including thought signatures). The controller re-sends
  /// them unchanged on tool follow-ups to the same provider.
  final List<Map<String, dynamic>>? responseOutputItems;

  /// Provider-reported usage, normally present only on the terminal event.
  final LlmUsage? usage;
}

/// One request message sent to a chat endpoint. This is
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
    this.imageFileIds = const [],
    this.responseOutputItems = const [],
    this.isToolImageObservation = false,
    this.toolImageCallId,
  });

  factory LlmRequestMessage.fromChatMessage(ChatMessage message) =>
      LlmRequestMessage(role: message.role, content: message.content);

  final MessageRole role;

  /// Transient screenshot observation; never serialized as a provider field.
  final bool isToolImageObservation;

  /// Local association between an observation and its producing tool call.
  /// Unlike [toolCallId], never serialized as an OpenAI message field.
  final String? toolImageCallId;
  final String content;
  final String? reasoningContent;
  final String? toolCallId;
  final List<ToolCall> toolCalls;

  /// `data:` or `http(s)` image URLs sent alongside [content] to a vision
  /// model. When non-empty (or [imageFileIds] is), `content` is serialized as
  /// an OpenAI multimodal parts array.
  final List<String> imageDataUrls;

  /// DeepSeek Files API ids (`file-api-…`) for images already uploaded.
  /// Prefer these over repeating large base64 payloads across turns.
  final List<String> imageFileIds;

  bool get hasImageParts => imageDataUrls.isNotEmpty || imageFileIds.isNotEmpty;

  /// Raw provider payload from a prior assistant step: Responses `output`
  /// items or Gemini content `parts`. Kept transient within a request's tool
  /// loop, so changing the conversation's provider never replays another
  /// protocol's items. The native provider uses these instead of rebuilding
  /// [content] / [toolCalls], preserving signatures and part boundaries.
  final List<Map<String, dynamic>> responseOutputItems;

  /// [includeReasoningContent] gates the `reasoning_content` round-trip:
  /// DeepSeek reasoners need the previous chain passed back for multi-turn
  /// thinking, while a strict provider that rejects unknown fields could 400
  /// on it. The provider decides from model capabilities; direct callers
  /// (tests) keep the historical default.
  Map<String, dynamic> toOpenAiJson({bool includeReasoningContent = true}) {
    final json = <String, dynamic>{
      'role': role.wire,
      'content': !hasImageParts
          ? content
          : [
              if (content.isNotEmpty) {'type': 'text', 'text': content},
              for (final id in imageFileIds) {'type': 'file', 'file_id': id},
              for (final url in imageDataUrls)
                {
                  'type': 'image_url',
                  'image_url': {'url': url},
                },
            ],
    };
    if (includeReasoningContent &&
        reasoningContent != null &&
        reasoningContent!.isNotEmpty) {
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
/// OpenAI / Responses `tool_choice: required` — call any exposed tool.
const kToolChoiceRequired = 'required';

/// DeepSeek V4 / Grok reasoning intensity. Official DeepSeek values are
/// `low` / `high` / `max` (`medium` and `xhigh` map to `high` server-side).
enum ReasoningEffort {
  low,
  high,
  max;

  String get wire => name;

  String get label => switch (this) {
    ReasoningEffort.low => '低',
    ReasoningEffort.high => '高',
    ReasoningEffort.max => '最大',
  };

  static ReasoningEffort fromWire(String? value) => switch (value) {
    'low' => ReasoningEffort.low,
    'max' => ReasoningEffort.max,
    'medium' || 'xhigh' || 'high' => ReasoningEffort.high,
    _ => ReasoningEffort.high,
  };
}

abstract class LlmProvider {
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    // DeepSeek V4 thinking-mode toggle. null = omit the field (use provider
    // default / non-DeepSeek providers); true/false = enable/disable.
    bool? thinking,
    // Used when [thinking] is true and the model accepts `reasoning_effort`.
    ReasoningEffort? reasoningEffort,
    // When non-null and [tools] is non-empty, force a tool call.
    // A function name becomes OpenAI `tool_choice: {type:function,...}`.
    // [kToolChoiceRequired] becomes `tool_choice: required`.
    String? forceToolName,
    // Cancels the in-flight HTTP request when the user presses stop, including
    // during connection setup (before any chunk has streamed).
    CancelToken? cancelToken,
  });
}
