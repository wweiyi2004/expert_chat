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
    this.serverWebSearch = false,
    this.forceServerWebSearch = false,
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

  /// Prefer the provider's Responses API + hosted `web_search` when the model
  /// advertises [ModelCapabilities.supportsServerWebSearch].
  final bool serverWebSearch;

  /// When [serverWebSearch] is on, force `tool_choice: web_search` (联网·强制).
  final bool forceServerWebSearch;

  ModelCapabilities get capabilities =>
      _capabilities ?? ModelCapabilities.resolve(model);

  bool get isReady => apiKey.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// Official DeepSeek API (Files API + V4 thinking fields live here).
  bool get isOfficialDeepSeek {
    final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
    return host == 'api.deepseek.com' || host.endsWith('.deepseek.com');
  }

  /// True when this request should hit Responses with server-side search.
  bool get useServerWebSearch =>
      serverWebSearch && capabilities.supportsServerWebSearch;

  LlmConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    ModelCapabilities? capabilities,
    bool? serverWebSearch,
    bool? forceServerWebSearch,
  }) => LlmConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    // Keep an explicit override only if one was set; otherwise stay null so a
    // changed [model] re-derives its own capabilities.
    capabilities: capabilities ?? _capabilities,
    serverWebSearch: serverWebSearch ?? this.serverWebSearch,
    forceServerWebSearch: forceServerWebSearch ?? this.forceServerWebSearch,
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

  /// Full Responses `output` items for the current turn. When non-null after
  /// `finish_reason: tool_calls`, the controller must re-send these items
  /// (plus `function_call_output`) on the next Responses request.
  final List<Map<String, dynamic>>? responseOutputItems;

  /// Provider-reported usage, normally present only on the terminal event.
  final LlmUsage? usage;
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
    this.imageFileIds = const [],
    this.responseOutputItems = const [],
  });

  factory LlmRequestMessage.fromChatMessage(ChatMessage message) =>
      LlmRequestMessage(role: message.role, content: message.content);

  final MessageRole role;
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

  /// Raw Responses API output items from a prior assistant turn that used
  /// server-side tools (`web_search_call`, `function_call`, `reasoning`…).
  /// When non-empty, the Responses provider re-sends them instead of
  /// synthesizing from [content] / [toolCalls].
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
    this.supportsServerWebSearch = false,
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

  /// Hosted `web_search` via the Responses API (DeepSeek V4 models).
  final bool supportsServerWebSearch;

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

    // Responses API lists flash / pro / vision-exp as supporting `web_search`.
    final deepseekV4 = m.startsWith('deepseek-v4');
    final serverWebSearch = deepseekV4;

    return ModelCapabilities(
      isReasoner: reasoner,
      supportsTools: tools,
      // DeepSeek-only request body field — never send to xAI/OpenAI/etc.
      sendThinkingField: deepseekV4,
      supportsVision: vision,
      // DeepSeek V4 uses `reasoning_effort` with thinking enabled; Grok uses
      // the same field, and Grok 4.3 additionally accepts `none`.
      supportsReasoningEffort: deepseekV4 || grok43 || grok45,
      reasoningCanBeDisabled: grok43,
      supportsServerWebSearch: serverWebSearch,
    );
  }
}

/// Known models surfaced in pickers and presets. Capability checks delegate to
/// [ModelCapabilities] so there is a single source of truth; these thin helpers
/// remain for call sites (e.g. the model picker) that only hold a model id.
class KnownModels {
  static const chat = 'deepseek-v4-flash';
  static const reasoner = 'deepseek-v4-pro';
  static const vision = 'deepseek-v4-flash-vision-exp';

  static const all = <String>[chat, reasoner, vision];

  static bool isReasoner(String model) =>
      ModelCapabilities.resolve(model).isReasoner;

  static bool supportsToolCalls(String model) =>
      ModelCapabilities.resolve(model).supportsTools;

  static bool supportsVision(String model) =>
      ModelCapabilities.resolve(model).supportsVision;
}
