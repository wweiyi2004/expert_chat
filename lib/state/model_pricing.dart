import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'work_session_insights.dart';

String modelPricingKey(String endpoint, String model) =>
    jsonEncode([endpoint, model]);

class ModelRate {
  const ModelRate({
    required this.input,
    required this.cached,
    required this.output,
    required this.currency,
  });
  final double input, cached, output;
  final String currency;
  Map<String, dynamic> toJson() => {
    'input': input,
    'cached': cached,
    'output': output,
    'currency': currency,
  };
  factory ModelRate.fromJson(Map<String, dynamic> j) => ModelRate(
    input: (j['input'] as num).toDouble(),
    cached: (j['cached'] as num).toDouble(),
    output: (j['output'] as num).toDouble(),
    currency: j['currency'] as String,
  );
}

class UsageEstimate {
  const UsageEstimate(this.amount, this.currency, this.complete);
  final double amount;
  final String currency;
  final bool complete;
}

UsageEstimate? estimateWorkCost(
  WorkSessionInsights insight,
  Map<String, ModelRate> rates,
) {
  var total = 0.0, known = 0;
  String? currency;
  for (final request in insight.requests.entries) {
    final usage = request.value;
    if (usage == null) continue;
    final rate = rates[insight.pricingKeys[request.key]];
    if (rate == null || (currency != null && currency != rate.currency)) {
      return null;
    }
    currency = rate.currency;
    known++;
    final cached = usage.cachedInputTokens.clamp(0, usage.inputTokens);
    total +=
        ((usage.inputTokens - cached) * rate.input +
            cached * rate.cached +
            usage.outputTokens * rate.output) /
        1000000;
  }
  return known == 0
      ? null
      : UsageEstimate(total, currency!, known == insight.requests.length);
}

final modelPricingProvider =
    NotifierProvider<ModelPricing, Map<String, ModelRate>>(ModelPricing.new);

class ModelPricing extends Notifier<Map<String, ModelRate>> {
  @override
  Map<String, ModelRate> build() {
    final raw = ref.read(sharedPrefsProvider).getString('modelPricing');
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map(
      (k, v) =>
          MapEntry(k, ModelRate.fromJson(Map<String, dynamic>.from(v as Map))),
    );
  }

  Future<void> save(String key, ModelRate rate) async {
    if ([
          rate.input,
          rate.cached,
          rate.output,
        ].any((v) => !v.isFinite || v < 0) ||
        rate.currency.trim().isEmpty) {
      throw const FormatException('单价须为非负数，币种不能为空');
    }
    final next = {...state, key: rate};
    if (!await ref
        .read(sharedPrefsProvider)
        .setString(
          'modelPricing',
          jsonEncode(next.map((k, v) => MapEntry(k, v.toJson()))),
        )) {
      throw StateError('单价未保存');
    }
    if (ref.mounted) state = next;
  }
}
