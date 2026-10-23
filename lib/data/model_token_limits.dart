/// Provider-reported token limits. Missing fields remain unknown, never zero.
class ModelTokenLimits {
  const ModelTokenLimits({
    this.contextWindowTokens,
    this.maxOutputTokens,
    this.inputLimitTokens,
  });
  final int? contextWindowTokens, maxOutputTokens, inputLimitTokens;
  bool get isKnown =>
      contextWindowTokens != null ||
      maxOutputTokens != null ||
      inputLimitTokens != null;
  Map<String, dynamic> toJson() => {
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
        contextWindowTokens: _positive(data['contextWindowTokens']),
        maxOutputTokens: _positive(data['maxOutputTokens']),
        inputLimitTokens: _positive(data['inputLimitTokens']),
      );
  factory ModelTokenLimits.fromModelApi(Map data) {
    final top = data['top_provider'] is Map
        ? data['top_provider'] as Map
        : const {};
    final input = _positive(
      data['inputTokenLimit'] ?? data['input_token_limit'],
    );
    final output = _positive(
      data['max_output_tokens'] ??
          data['outputTokenLimit'] ??
          data['max_completion_tokens'] ??
          top['max_completion_tokens'],
    );
    final total = _positive(
      data['context_window'] ??
          data['context_length'] ??
          data['contextWindowTokens'] ??
          top['context_length'],
    );
    return ModelTokenLimits(
      contextWindowTokens:
          total ?? (input == null ? null : input + (output ?? 0)),
      inputLimitTokens: input,
      maxOutputTokens: output,
    );
  }
}
