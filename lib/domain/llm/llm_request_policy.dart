import 'llm_provider.dart';

/// Request decisions only: no settings store, Riverpod state, timers or I/O.
/// Controllers supply a snapshot; adapters still own protocol serialization.
abstract final class LlmRequestPolicy {
  static const reasoningTimeout = Duration(seconds: 60);
  static const maxReasoningChars = 12000;
  static const recoveryTimeout = Duration(seconds: 20);
  static const maxRecoveryChars = 4000;
  static const finalAnswerTimeout = Duration(seconds: 20);
  static const maxReasoningAttempts = 2;

  static LlmConfig selectModel({
    required LlmConfig selected,
    required String reasonerModel,
    required bool thinking,
    bool hasImages = false,
    bool hasVisionFallback = false,
    bool selectedExplicitly = false,
  }) {
    final capabilities = selected.capabilities;
    final reasonerCapabilities = ModelCapabilities.resolve(reasonerModel);
    final hasReasoner =
        reasonerCapabilities.isReasoner ||
        reasonerCapabilities.supportsReasoningEffort ||
        reasonerCapabilities.sendThinkingField;
    final candidate =
        !thinking ||
            selectedExplicitly ||
            capabilities.sendThinkingField ||
            capabilities.supportsReasoningEffort ||
            capabilities.isReasoner ||
            !hasReasoner
        ? selected
        : selected.copyWith(model: reasonerModel);
    if (hasImages &&
        !candidate.capabilities.supportsVision &&
        !hasVisionFallback &&
        selected.capabilities.supportsVision) {
      return selected;
    }
    return candidate;
  }

  static ReasoningEffort selectEffort({
    required LlmConfig config,
    required ReasoningEffort savedEffort,
    required bool hasSavedOverride,
    required bool proseTask,
    required bool workMode,
    ReasoningEffort? manualEffort,
  }) {
    if (manualEffort != null) return manualEffort;
    // Settings decode missing preferences as High. Task classification must
    // not silently lower that default; saved/manual Low or Max stay valid.
    return savedEffort;
  }

  /// A document edit has priority. Multiple other forced tools require at
  /// least one tool call; the model chooses their order.
  static String? forcedToolChoice({
    String? documentTool,
    String? imageTool,
    String? searchTool,
  }) {
    if (documentTool != null) return documentTool;
    if (imageTool != null && searchTool != null) return kToolChoiceRequired;
    return imageTool ?? searchTool;
  }

  static bool canUseTools(LlmConfig config, List<ToolSpec>? tools) =>
      config.capabilities.supportsTools && tools != null && tools.isNotEmpty;

  static bool allowToolsThisRound({
    required int round,
    required int maxRounds,
    required bool enableTools,
    required bool hasToolSpecs,
  }) => enableTools && hasToolSpecs && round < maxRounds - 1;

  static LlmRoundRequest forRound({
    required LlmConfig config,
    required bool thinking,
    required ReasoningEffort reasoningEffort,
    required List<ToolSpec> tools,
    required bool enableTools,
    required int round,
    required int maxRounds,
    required bool finalizing,
    String? forceToolName,
  }) {
    final allowTools =
        !finalizing &&
        allowToolsThisRound(
          round: round,
          maxRounds: maxRounds,
          enableTools: enableTools,
          hasToolSpecs: canUseTools(config, tools),
        );
    return LlmRoundRequest(
      config: finalizing
          ? config.copyWith(
              serverWebSearch: false,
              forceServerWebSearch: false,
              allowReasoningRetry: false,
            )
          : round == 0
          ? config
          : config.copyWith(forceServerWebSearch: false),
      tools: allowTools ? tools : null,
      thinking: finalizing ? false : thinking,
      reasoningEffort: !finalizing && thinking ? reasoningEffort : null,
      forceToolName: allowTools && round == 0 ? forceToolName : null,
    );
  }

  /// The guard executes this plan. Overrides preserve deterministic tests and
  /// existing deployments that customize watchdog limits.
  static ReasoningAttemptPolicy reasoningAttempt({
    required LlmConfig config,
    required int attempt,
    required bool? thinking,
    required ReasoningEffort? reasoningEffort,
    Duration timeout = reasoningTimeout,
    int charLimit = maxReasoningChars,
    Duration retryTimeout = recoveryTimeout,
    int retryCharLimit = maxRecoveryChars,
  }) {
    final recovering = attempt > 0;
    final low = reasoningEffort == ReasoningEffort.low;
    final multiplier = reasoningEffort == ReasoningEffort.max ? 2 : 1;
    return ReasoningAttemptPolicy(
      config: recovering
          ? config.copyWith(forceServerWebSearch: false)
          : config,
      thinking: recovering ? false : thinking,
      reasoningEffort: recovering ? null : reasoningEffort,
      timeout: recovering
          ? retryTimeout
          : low
          ? timeout ~/ 2
          : timeout * multiplier,
      charLimit: recovering
          ? retryCharLimit
          : low
          ? charLimit ~/ 2
          : charLimit * multiplier,
      mayRetry: config.isDeepSeek && !recovering && config.allowReasoningRetry,
    );
  }
}

class LlmRoundRequest {
  const LlmRoundRequest({
    required this.config,
    required this.tools,
    required this.thinking,
    required this.reasoningEffort,
    required this.forceToolName,
  });
  final LlmConfig config;
  final List<ToolSpec>? tools;
  final bool thinking;
  final ReasoningEffort? reasoningEffort;
  final String? forceToolName;
}

class ReasoningAttemptPolicy {
  const ReasoningAttemptPolicy({
    required this.config,
    required this.thinking,
    required this.reasoningEffort,
    required this.timeout,
    required this.charLimit,
    required this.mayRetry,
  });
  final LlmConfig config;
  final bool? thinking;
  final ReasoningEffort? reasoningEffort;
  final Duration timeout;
  final int charLimit;
  final bool mayRetry;
}
