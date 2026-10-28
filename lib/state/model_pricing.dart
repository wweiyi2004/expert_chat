import 'dart:convert';
import 'package:riverpod/riverpod.dart';
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
    final key = insight.pricingKeys[request.key];
    final rate = rates[key] ?? referenceModelRate(key, usage.inputTokens);
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

// Reference USD / million tokens, retrieved 2026-10-27. These are estimates,
// not reseller invoices. DeepSeek uses peak rates (off-peak is half).
// https://api-docs.deepseek.com/quick_start/pricing/
// https://platform.claude.com/docs/en/about-claude/pricing
// https://developers.openai.com/api/docs/models/gpt-5.4
ModelRate? referenceModelRate(String? key, int inputTokens) {
  if(key==null)return null;
  String model;
  try {model=(jsonDecode(key) as List).last.toString().toLowerCase().split('/').last;}
  catch(_){return null;}
  model=model.replaceFirst(RegExp(r'-\d{4}-\d{2}-\d{2}$'), '').replaceFirst(RegExp(r'-\d{8}$'), '');
  final rates=<String,(double,double,double)>{
    'deepseek-flash':(.30,.006,1.20),'deepseek-v4.1-flash':(.30,.006,1.20),
    'deepseek-v4-flash':(.30,.006,1.20),'deepseek-v4-flash-vision-exp':(.30,.006,1.20),
    'deepseek-v4-pro':(1.32,.044,3.96),
    'claude-opus-5-5':(4,.2,20),'claude-sonnet-5-5':(2,.1,10),
    'claude-opus-4-6':(5,.5,25),'claude-opus-4-5':(5,.5,25),
    'claude-sonnet-4-6':(3,.3,15),'claude-sonnet-4-5':(3,.3,15),
    'claude-haiku-4-5':(1,.1,5),
    'gpt-5.4': inputTokens>272000 ? (5,.5,22.5) : (2.5,.25,15),
  };
  final rate=rates[model];
  return rate==null ? null : ModelRate(input:rate.$1,cached:rate.$2,output:rate.$3,currency:'USD');
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
