/// Provider-reported token limits. Missing fields remain unknown, never zero.
class ModelTokenLimits {
  const ModelTokenLimits({
    this.contextWindowTokens,
    this.maxOutputTokens,
    this.inputLimitTokens,
    this.reasoningEfforts,
    this.reasoningCanBeDisabled,
    this.supportsTools,
    this.supportsVision,
    this.apiFormat,
  });
  final int? contextWindowTokens, maxOutputTokens, inputLimitTokens;
  final List<String>? reasoningEfforts;
  final bool? reasoningCanBeDisabled;
  final bool? supportsTools,supportsVision;
  final String? apiFormat;
  bool get isKnown =>
      reasoningEfforts != null ||
      supportsTools != null || supportsVision != null || apiFormat != null ||
      reasoningCanBeDisabled != null ||
      contextWindowTokens != null ||
      maxOutputTokens != null ||
      inputLimitTokens != null;
  Map<String, dynamic> toJson() => {
    if(apiFormat!=null)'apiFormat':apiFormat,
    if(supportsTools!=null)'supportsTools':supportsTools,
    if(supportsVision!=null)'supportsVision':supportsVision,
    if (reasoningEfforts != null) 'reasoningEfforts': reasoningEfforts,
    if (reasoningCanBeDisabled != null)
      'reasoningCanBeDisabled': reasoningCanBeDisabled,
    if (contextWindowTokens != null) 'contextWindowTokens': contextWindowTokens,
    if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
    if (inputLimitTokens != null) 'inputLimitTokens': inputLimitTokens,
  };
  static int? _positive(dynamic value) {
    final n = value is num ? value.toInt() : int.tryParse('$value');
    return n != null && n > 0 ? n : null;
  }

  factory ModelTokenLimits.fromJson(Map<String, dynamic> data) =>
      ModelTokenLimits(
        apiFormat:data['apiFormat'] as String?,
        supportsTools:data['supportsTools'] as bool?,supportsVision:data['supportsVision'] as bool?,
        reasoningEfforts: _efforts(data['reasoningEfforts']),
        reasoningCanBeDisabled: data['reasoningCanBeDisabled'] as bool?,
        contextWindowTokens: _positive(data['contextWindowTokens']),
        maxOutputTokens: _positive(data['maxOutputTokens']),
        inputLimitTokens: _positive(data['inputLimitTokens']),
      );
  static List<String>? _efforts(dynamic value) {
    if (value is! List) return null;
    final known = value
        .map((v) => v is Map ? v['effort'] : v)
        .whereType<String>()
        .where(
          (v) => const [
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
          ].contains(v),
        )
        .toSet()
        .toList();
    return known.isEmpty ? null : known;
  }

  factory ModelTokenLimits.fromModelApi(Map data,{bool kimiCode=false}) {
    final reasoning=data['reasoning'] is Map?data['reasoning'] as Map:const {};
    final effort=reasoning['effort'] is Map?reasoning['effort'] as Map:const {};
    final limit=data['limit'] is Map?data['limit'] as Map:const {};
    final modalities=data['modalities'] is Map?data['modalities'] as Map:const {};
    final reportedEfforts =
        data['supported_reasoning_levels'] ??
        data['supported_reasoning_efforts'] ?? data['support_efforts'] ?? effort['valid'];
    final allowsNone = reportedEfforts is List
        ? reportedEfforts.any((v) => (v is Map ? v['effort'] : v) == 'none')
        : null;
    final top = data['top_provider'] is Map
        ? data['top_provider'] as Map
        : const {};
    final input = _positive(
      data['inputTokenLimit'] ?? data['input_token_limit'],
    );
    final output = _positive(
      data['max_output_tokens'] ??
          limit['output'] ??
          data['outputTokenLimit'] ??
          data['max_completion_tokens'] ??
          top['max_completion_tokens'],
    );
    final total = _positive(
      data['context_window'] ??
          limit['context'] ??
          data['context_length'] ??
          data['contextWindowTokens'] ??
          top['context_length'],
    );
    return ModelTokenLimits(
      apiFormat:kimiCode?switch(data['protocol']){'response'=>'openAiResponses','anthropic'=>'anthropicMessages',_=>null}:null,
      supportsTools:data['supports_tool_use'] is bool?data['supports_tool_use'] as bool:kimiCode?true:null,
      supportsVision:data['supports_image_in'] is bool?data['supports_image_in'] as bool:modalities['input'] is List?(modalities['input'] as List).contains('image'):null,
      reasoningEfforts: _efforts(reportedEfforts),
      reasoningCanBeDisabled: switch(data['supports_thinking_type']??reasoning['type']){'only'=>false,'both'=>true,_=>allowsNone},
      contextWindowTokens:
          total ?? (input == null ? null : input + (output ?? 0)),
      inputLimitTokens: input,
      maxOutputTokens: output,
    );
  }
}
