export 'gemini_endpoint.dart';

/// What a given model can do, used to shape the request (which optional
/// fields/params are safe to send) and the UI (the reasoning panel). Resolved
/// from the model id in [resolve] — the ONE place that encodes provider-specific
/// heuristics — but can also be supplied explicitly on `LlmConfig` to override.
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
  factory ModelCapabilities.resolve(String model) =>
      ModelCatalog.resolve(model);
}

/// Known models surfaced in pickers and presets. Capability checks delegate to
/// [ModelCapabilities] so there is a single source of truth; these thin helpers
/// remain for call sites (e.g. the model picker) that only hold a model id.
class KnownModels {
  static const flash = 'deepseek-flash';
  static const chat = 'deepseek-v4-flash';
  static const reasoner = 'deepseek-v4-pro';
  static const vision = 'deepseek-v4-flash-vision-exp';

  static const all = <String>[flash, chat, reasoner, vision];

  static bool isReasoner(String model) =>
      ModelCapabilities.resolve(model).isReasoner;

  static bool supportsToolCalls(String model) =>
      ModelCapabilities.resolve(model).supportsTools;

  static bool supportsVision(String model) =>
      ModelCapabilities.resolve(model).supportsVision;
}

/// Explicit built-in capabilities take priority over compatibility heuristics.
/// Existing aliases intentionally keep their previous behavior in this refactor.
abstract final class ModelCatalog {
  static const entries = <String, ModelCapabilities>{
    KnownModels.flash: ModelCapabilities(
      isReasoner: false,
      supportsTools: true,
      sendThinkingField: true,
      supportsVision: true,
      supportsReasoningEffort: true,
    ),
    KnownModels.chat: ModelCapabilities(
      isReasoner: false,
      supportsTools: true,
      sendThinkingField: true,
      supportsVision: false,
      supportsReasoningEffort: true,
      supportsServerWebSearch: true,
    ),
    KnownModels.reasoner: ModelCapabilities(
      isReasoner: true,
      supportsTools: true,
      sendThinkingField: true,
      supportsVision: false,
      supportsReasoningEffort: true,
      supportsServerWebSearch: true,
    ),
    KnownModels.vision: ModelCapabilities(
      isReasoner: false,
      supportsTools: true,
      sendThinkingField: true,
      supportsVision: true,
      supportsReasoningEffort: true,
      supportsServerWebSearch: true,
    ),
    'grok-4.3': ModelCapabilities(
      isReasoner: false,
      supportsTools: true,
      sendThinkingField: false,
      supportsVision: true,
      supportsReasoningEffort: true,
      reasoningCanBeDisabled: true,
    ),
    'grok-4.5': ModelCapabilities(
      isReasoner: true,
      supportsTools: true,
      sendThinkingField: false,
      supportsVision: true,
      supportsReasoningEffort: true,
    ),
  };

  static String normalizeId(String model) =>
      model.toLowerCase().split('/').last;

  static bool isOfficialDeepSeekEndpoint(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
    return host == 'api.deepseek.com' || host.endsWith('.deepseek.com');
  }

  static bool isDeepSeek({required String baseUrl, required String model}) =>
      isOfficialDeepSeekEndpoint(baseUrl) ||
      model.toLowerCase().contains('deepseek');

  /// True for Gemini 2.5+ / 3+ / thinking models that accept `thinkingConfig`
  /// in native Gemini `generationConfig`.
  static bool supportsGeminiThinkingConfig(String model) {
    final m = normalizeId(model);
    return m.startsWith('gemini-2.5') ||
        m.startsWith('gemini-3') ||
        (m.startsWith('gemini') && m.contains('thinking'));
  }

  static ModelCapabilities resolve(String model) =>
      entries[normalizeId(model)] ?? _inferCapabilities(model);

  static ModelCapabilities _inferCapabilities(String model) {
    // Aggregator gateways expose ids as vendor/model (qwen/qwen3-max,
    // deepseek-ai/deepseek-v4); capabilities depend on the model segment only.
    final m = normalizeId(model);
    final deepseekFlash = m == 'deepseek-flash';
    final deepseekV4 = deepseekFlash || m.startsWith('deepseek-v4');
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
    if (deepseekV4 ||
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
        deepseekFlash ||
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

    // V4.1 Flash ignores built-in `web_search`; retain the legacy V4 policy.
    final serverWebSearch = !deepseekFlash && deepseekV4;

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
