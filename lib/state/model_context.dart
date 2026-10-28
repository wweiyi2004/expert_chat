import 'dart:convert';
import '../data/context_prefs.dart';
import '../data/model_token_limits.dart';
import '../data/settings_state.dart';
import '../domain/llm/llm_provider.dart';

String modelContextKey(String endpoint, String model) =>
    jsonEncode([endpoint.trim().replaceFirst(RegExp(r'/+$'), ''), model]);
ModelTokenLimits? reportedModelLimits(
  SettingsState settings,
  LlmConfig config,
) {
  final url = config.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  final profile = settings.profiles
      .where(
        (p) =>
            (config.profileId == null || p.id == config.profileId) &&
            p.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '') == url,
      )
      .firstOrNull;
  return profile?.modelLimits[config.model];
}

ContextPrefs effectiveContextPrefs(SettingsState settings, LlmConfig config) {
  final override =
      settings.modelContexts[modelContextKey(config.baseUrl, config.model)];
  final defaults = override ?? settings.context;
  final limits = reportedModelLimits(settings, config);
  var window = defaults.contextWindowTokens;
  if (limits?.contextWindowTokens != null) {
    window = override == null
        ? limits!.contextWindowTokens!
        : window.clamp(4096, limits!.contextWindowTokens!.clamp(4096, 2000000));
  }
  window = window.clamp(4096, 2000000);
  var output = defaults.maxOutputTokens;
  if (output == 0) output = limits?.maxOutputTokens ?? 0;
  if (limits?.maxOutputTokens != null && output > limits!.maxOutputTokens!) {
    output = limits.maxOutputTokens!;
  }
  // Imported or legacy settings must not reserve a larger response than the window.
  if (output >= window) output = (window ~/ 4).clamp(512, 32768);
  final reserve = defaults.reservedOutputTokens.clamp(512, window - 1024);
  return ContextPrefs(
    enabled: defaults.enabled,
    contextWindowTokens: window,
    maxOutputTokens: output,
    reservedOutputTokens: reserve,
    maxHistoryMessages: defaults.maxHistoryMessages,
    inputLimitTokens: limits?.inputLimitTokens,
  );
}

LlmConfig applyContextConfig(LlmConfig config, ContextPrefs prefs) =>
    config.copyWith(
      maxOutputTokens: prefs.maxOutputTokens > 0 ? prefs.maxOutputTokens : null,
      clearMaxOutputTokens: prefs.maxOutputTokens == 0,
    );
Map<String, ContextPrefs> decodeModelContexts(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return {};
  return {
    for (final entry in decoded.entries)
      if (entry.key is String && entry.value is Map)
        entry.key as String: ContextPrefs.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        ),
  };
}

LlmConfig applyReportedModelCapabilities(
  SettingsState settings,
  LlmConfig config,
) {
  final metadata = reportedModelLimits(settings, config);
  return config.copyWith(
    apiFormat:config.apiFormat==LlmApiFormat.auto&&metadata?.apiFormat!=null?LlmApiFormat.fromWire(metadata!.apiFormat):null,
    capabilities: ModelCapabilities.resolve(config.model).withReasoning(
      efforts: metadata?.reasoningEfforts,
      canDisable: metadata?.reasoningCanBeDisabled,
      tools:metadata?.supportsTools,
      vision:metadata?.supportsVision,
    ),
  );
}
