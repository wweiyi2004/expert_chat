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
    this.reasoningEffortValues,
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
  final List<String>? reasoningEffortValues;

  ModelCapabilities withReasoning({List<String>? efforts, bool? canDisable,bool? tools,bool? vision}) =>
      ModelCapabilities(
        isReasoner: efforts != null ? true : isReasoner,
        supportsTools: tools ?? supportsTools,
        sendThinkingField: sendThinkingField,
        supportsVision: vision ?? supportsVision,
        supportsReasoningEffort: efforts != null || supportsReasoningEffort,
        reasoningCanBeDisabled: canDisable ?? reasoningCanBeDisabled,
        supportsServerWebSearch: supportsServerWebSearch,
        reasoningEffortValues: efforts ?? reasoningEffortValues,
      );

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

  static const all = <String>[flash, reasoner];

  static bool isReasoner(String model) =>
      ModelCapabilities.resolve(model).isReasoner;

  static bool supportsToolCalls(String model) =>
      ModelCapabilities.resolve(model).supportsTools;

  static bool supportsVision(String model) =>
      ModelCapabilities.resolve(model).supportsVision;
}

/// Explicit built-in capabilities take priority over compatibility heuristics.
/// Retired Flash aliases follow the current Flash vision capabilities.
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
      supportsVision: true,
      supportsReasoningEffort: true,
      supportsServerWebSearch: false,
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
      supportsServerWebSearch: false,
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

  // Verified official model pages, 2026-10-25. Unknown GPT ids stay conservative.
  static List<String> reasoningEfforts(String model) {
    final m = normalizeId(model);
    if (RegExp(
      r'^gpt-(?:(?:6-(?:sol|astra|luna)|6\.1-sol)|5\.6(?:-sol)?)(?:$|-)',
    ).hasMatch(m)) {
      return const ['low', 'medium', 'high', 'xhigh', 'max'];
    }
    if (RegExp(r'^gpt-5\.[2-5](?:$|-)').hasMatch(m)) {
      return const ['low', 'medium', 'high', 'xhigh'];
    }
    if (m.startsWith('gpt-5.1') || RegExp(r'^o[134](?:$|-)').hasMatch(m)) {
      return const ['low', 'medium', 'high'];
    }
    if (m == 'gpt-5' ||
        m.startsWith('gpt-5-mini') ||
        m.startsWith('gpt-5-nano')) {
      return const ['minimal', 'low', 'medium', 'high'];
    }
    return const ['low', 'high', 'max'];
  }

  static bool isConfigurableGpt(String model) {
    final m = normalizeId(model);
    if (m.contains('-chat') || m.contains('-pro')) return false;
    return RegExp(
      r'^gpt-(?:5(?:$|-|\.[1-6](?:$|-))|(?:6-(?:sol|astra|luna)|6\.1-sol)(?:$|-))',
    ).hasMatch(m);
  }

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
    final kimiK3=RegExp(r'^k3(?:[.-]|$)').hasMatch(m);
    final nonReasoning = m.contains('non-reasoning');
    final grok43 =
        m == 'grok-4.3' || m.startsWith('grok-4.3-') || m == 'grok-4.3-latest';
    final grok45 =
        m == 'grok-4.5' || m.startsWith('grok-4.5-') || m == 'grok-4.5-latest';

    // Broadened vs. the old check to also catch `*-thinking-*` reasoners (e.g.
    // kimi-thinking-preview, GLM thinking variants), which previously did not
    // light up the panel. xAI Grok: `grok-*-reasoning` / mini reasoning paths.
    final configurableGpt = isConfigurableGpt(m);
    final reasoner =
        kimiK3 ||
        configurableGpt ||
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
    if (deepseekV4 || kimiK3 ||
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
        kimiK3 ||
        (configurableGpt && m.startsWith('gpt-6')) ||
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
        RegExp(r'^claude-(?:sonnet|opus|haiku)-[4-9]').hasMatch(m) ||
        m.contains('pixtral') ||
        m.contains('llava') ||
        m.contains('internvl') ||
        (m.startsWith('grok') &&
            (m.contains('vision') ||
                (m.startsWith('grok-4.') && !m.contains('build'))));

    // Only Pro supports hosted Responses web_search. Flash uses Search / Fetch.
    final serverWebSearch = m == 'deepseek-v4-pro';

    return ModelCapabilities(
      isReasoner: reasoner,
      supportsTools: tools,
      // DeepSeek-only request body field — never send to xAI/OpenAI/etc.
      sendThinkingField: deepseekV4,
      supportsVision: vision,
      // DeepSeek V4 uses `reasoning_effort` with thinking enabled; Grok uses
      // the same field, and Grok 4.3 additionally accepts `none`.
      supportsReasoningEffort:
          deepseekV4 || grok43 || grok45 || configurableGpt,
      reasoningCanBeDisabled:
          grok43 ||
          (configurableGpt &&
              !m.startsWith('gpt-6.1-sol') &&
              !m.startsWith('gpt-6-astra') &&
              !m.contains('-pro') &&
              m != 'gpt-5' &&
              !m.startsWith('gpt-5-mini') &&
              !m.startsWith('gpt-5-nano')),
      supportsServerWebSearch: serverWebSearch,
    );
  }
}
