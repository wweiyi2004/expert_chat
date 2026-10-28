import 'dart:async';
import 'dart:convert';
import '../core/providers.dart';
import 'package:riverpod/riverpod.dart';
import '../domain/llm/llm_provider.dart';
import 'model_pricing.dart' show modelPricingKey;

enum WorkRequestKind { task, auxiliary, title }

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
    this.requestKinds = const {},
  });
  final List<LlmRequestMessage> messages;
  final List<ToolSpec> tools;
  final String model;
  final int? contextBudgetTokens;
  // Terminal usage can be repeated in a stream: replace by request id.
  final Map<String, LlmUsage?> requests;
  final Map<String, String> pricingKeys;
  final Map<String, WorkRequestKind> requestKinds;
  int countRequests(WorkRequestKind kind) => requests.keys
      .where((id) => (requestKinds[id] ?? WorkRequestKind.task) == kind)
      .length;
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
  Map<String, WorkSessionInsights> build() {
    final prefs = ref.read(sharedPrefsProvider);
    var restored = <String, WorkSessionInsights>{};
    try {
      final raw =
          jsonDecode(prefs.getString('sessionUsageLedgerV1') ?? '{}') as Map;
      restored = raw.map((id, data) {
        final v = Map<String, dynamic>.from(data as Map);
        return MapEntry(
          id.toString(),
          WorkSessionInsights(
            requests: (v['requests'] as Map).map(
              (id, u) => MapEntry(
                id.toString(),
                u == null
                    ? null
                    : LlmUsage(
                        inputTokens: (u['input'] as num).toInt(),
                        outputTokens: (u['output'] as num).toInt(),
                        cachedInputTokens: (u['cached'] as num?)?.toInt() ?? 0,
                        cacheReported: u['cacheReported'] == true,
                        cost: (u['cost'] as num?)?.toDouble(),
                        currency: u['currency'] as String?,
                      ),
              ),
            ),
            pricingKeys: Map<String, String>.from(
              v['pricingKeys'] as Map? ?? {},
            ),
            requestKinds: (v['kinds'] as Map? ?? {}).map(
              (id, kind) => MapEntry(
                id.toString(),
                WorkRequestKind.values.firstWhere(
                  (k) => k.name == kind,
                  orElse: () => WorkRequestKind.task,
                ),
              ),
            ),
          ),
        );
      });
    } catch (_) {
      /* A malformed ledger never prevents opening conversations. */
    }
    listenSelf((_, next) {
      final encoded = jsonEncode(
        next.map(
          (id, v) => MapEntry(id, {
            'requests': v.requests.map(
              (key, u) => MapEntry(
                key,
                u == null
                    ? null
                    : {
                        'input': u.inputTokens,
                        'output': u.outputTokens,
                        'cached': u.cachedInputTokens,
                        'cacheReported': u.cacheReported,
                        'cost': u.cost,
                        'currency': u.currency,
                      },
              ),
            ),
            'pricingKeys': v.pricingKeys,
            'kinds': v.requestKinds.map((id, k) => MapEntry(id, k.name)),
          }),
        ),
      );
      _writes = _writes
          .then((_) async {
            await prefs.setString('sessionUsageLedgerV1', encoded);
          })
          .catchError((Object _, StackTrace _) {});
    });
    return restored;
  }

  Future<void> _writes = Future.value();

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
        requestKinds: {...old.requestKinds, id: WorkRequestKind.task},
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
        model:
            (old.requestKinds[id] ?? WorkRequestKind.task) ==
                WorkRequestKind.task
            ? config.model
            : old.model,
        contextBudgetTokens: contextBudgetTokens ?? old.contextBudgetTokens,
        requests: old.requests,
        requestKinds: old.requestKinds,
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
        requestKinds: old.requestKinds,
        pricingKeys: old.pricingKeys,
      ),
    };
  }

  void auxiliaryRequest(
    String conversation,
    String id,
    LlmConfig config, {
    WorkRequestKind kind = WorkRequestKind.auxiliary,
  }) {
    final old = state[conversation] ?? const WorkSessionInsights();
    state = {
      ...state,
      conversation: WorkSessionInsights(
        messages: old.messages,
        tools: old.tools,
        model: old.model,
        contextBudgetTokens: old.contextBudgetTokens,
        requests: {...old.requests, id: null},
        requestKinds: {...old.requestKinds, id: kind},
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
