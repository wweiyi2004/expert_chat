import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/llm/llm_provider.dart';
import 'model_pricing.dart' show modelPricingKey;

/// Latest request and this app session's usage, isolated by conversation.
/// Request snapshots stay in memory; credentials and HTTP headers aren't kept.
class WorkSessionInsights {
  const WorkSessionInsights({
    this.messages = const [],
    this.tools = const [],
    this.model = '',
    this.requests = const {},
    this.pricingKeys = const {},
    this.contextBudgetTokens,
  });
  final List<LlmRequestMessage> messages;
  final List<ToolSpec> tools;
  final String model;
  final int? contextBudgetTokens;
  // Terminal usage can be repeated in a stream: replace by request id.
  final Map<String, LlmUsage?> requests;
  final Map<String, String> pricingKeys;
  int get inputTokens =>
      requests.values.fold(0, (n, u) => n + (u?.inputTokens ?? 0));
  int get outputTokens =>
      requests.values.fold(0, (n, u) => n + (u?.outputTokens ?? 0));
  int get cachedTokens =>
      requests.values.fold(0, (n, u) => n + (u?.cachedInputTokens ?? 0));
  Iterable<LlmUsage> get _reportedCacheUsage => requests.values
      .whereType<LlmUsage>()
      .where((u) => u.cacheReported || u.cachedInputTokens > 0);
  int get cacheReportedRequests => _reportedCacheUsage.length;
  // Missing requests are excluded from both sides of the live ratio.
  double? get cacheHitRate {
    var input = 0;
    var cached = 0;
    for (final usage in _reportedCacheUsage) {
      input += usage.inputTokens;
      cached += usage.cachedInputTokens;
    }
    return input > 0 ? cached / input : null;
  }

  bool get cacheComplete =>
      requests.isNotEmpty &&
      requests.values.every(
        (u) => u != null && (u.cacheReported || u.cachedInputTokens > 0),
      );
  String? get currency {
    final currencies = requests.values.map((u) => u?.currency).toSet();
    return currencies.length == 1 && currencies.first?.isNotEmpty == true
        ? currencies.first
        : null;
  }

  double? get cost =>
      currency != null &&
          requests.values.every(
            (u) => u?.cost != null && u!.cost!.isFinite && u.cost! >= 0,
          )
      ? requests.values.fold<double>(0, (n, u) => n + u!.cost!)
      : null;
}

class WorkSessionInsightsController
    extends Notifier<Map<String, WorkSessionInsights>> {
  @override
  Map<String, WorkSessionInsights> build() => {};

  void request(
    String conversation,
    String id,
    String model,
    List<LlmRequestMessage> messages,
    List<ToolSpec> tools, {
    String endpoint = '',
    int? contextBudgetTokens,
  }) {
    final old = state[conversation] ?? const WorkSessionInsights();
    state = {
      ...state,
      conversation: WorkSessionInsights(
        messages: List.unmodifiable(messages),
        tools: List.unmodifiable(tools),
        model: model,
        contextBudgetTokens: contextBudgetTokens ?? old.contextBudgetTokens,
        requests: {...old.requests, id: null},
        pricingKeys: {...old.pricingKeys, id: modelPricingKey(endpoint, model)},
      ),
    };
  }

  void route(
    String conversation,
    String id,
    LlmConfig config, {
    int? contextBudgetTokens,
  }) {
    final old = state[conversation];
    if (old == null) return;
    state = {
      ...state,
      conversation: WorkSessionInsights(
        messages: old.messages,
        tools: old.tools,
        model: config.model,
        contextBudgetTokens: contextBudgetTokens ?? old.contextBudgetTokens,
        requests: old.requests,
        pricingKeys: {
          ...old.pricingKeys,
          id: modelPricingKey(config.baseUrl, config.model),
        },
      ),
    };
  }

  void usage(String conversation, String id, LlmUsage usage) {
    final old = state[conversation];
    if (old == null) return;
    state = {
      ...state,
      conversation: WorkSessionInsights(
        messages: old.messages,
        tools: old.tools,
        model: old.model,
        contextBudgetTokens: old.contextBudgetTokens,
        requests: {...old.requests, id: usage},
        pricingKeys: old.pricingKeys,
      ),
    };
  }

  void auxiliaryRequest(String conversation, String id, LlmConfig config) {
    final old = state[conversation] ?? const WorkSessionInsights();
    state = {
      ...state,
      conversation: WorkSessionInsights(
        messages: old.messages,
        tools: old.tools,
        model: old.model,
        contextBudgetTokens: old.contextBudgetTokens,
        requests: {...old.requests, id: null},
        pricingKeys: {
          ...old.pricingKeys,
          id: modelPricingKey(config.baseUrl, config.model),
        },
      ),
    };
  }
}

final workSessionInsightsProvider =
    NotifierProvider<
      WorkSessionInsightsController,
      Map<String, WorkSessionInsights>
    >(WorkSessionInsightsController.new);
