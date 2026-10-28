class ContextPrefs {
  const ContextPrefs({
    this.enabled = true,
    this.contextWindowTokens = 1000000,
    this.reservedOutputTokens = 4096,
    this.maxHistoryMessages = 0,
    this.maxOutputTokens = 0,
    this.inputLimitTokens,
  });

  final bool enabled;
  final int? inputLimitTokens;

  /// Total context window advertised by the selected model.
  final int contextWindowTokens;

  /// Space kept free for the model's response.
  final int reservedOutputTokens;

  /// Maximum non-system messages; zero selects by token budget only.
  final int maxHistoryMessages;

  /// Zero uses the reported model output maximum, or the provider default when unknown.
  final int maxOutputTokens;

  int get effectiveOutputReserve {
    final output = maxOutputTokens >= contextWindowTokens
        ? (contextWindowTokens ~/ 4).clamp(512, 32768)
        : maxOutputTokens;
    return (output > reservedOutputTokens ? output : reservedOutputTokens)
        .clamp(512, contextWindowTokens - 1024);
  }

  int get inputBudgetTokens {
    final budget = (contextWindowTokens - effectiveOutputReserve).clamp(
      1024,
      contextWindowTokens,
    );
    return inputLimitTokens != null &&
            inputLimitTokens! > 0 &&
            inputLimitTokens! < budget
        ? inputLimitTokens!
        : budget;
  }

  ContextPrefs copyWith({
    bool? enabled,
    int? contextWindowTokens,
    int? reservedOutputTokens,
    int? maxHistoryMessages,
    int? maxOutputTokens,
    int? inputLimitTokens,
  }) => ContextPrefs(
    enabled: enabled ?? this.enabled,
    inputLimitTokens: inputLimitTokens ?? this.inputLimitTokens,
    contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    reservedOutputTokens: reservedOutputTokens ?? this.reservedOutputTokens,
    maxHistoryMessages: maxHistoryMessages ?? this.maxHistoryMessages,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    if (inputLimitTokens != null) 'inputLimitTokens': inputLimitTokens,
    'contextWindowTokens': contextWindowTokens,
    'reservedOutputTokens': reservedOutputTokens,
    'maxHistoryMessages': maxHistoryMessages,
    'maxOutputTokens': maxOutputTokens,
  };

  factory ContextPrefs.fromJson(Map<String, dynamic> json) {
    final window = ((json['contextWindowTokens'] as num?)?.toInt() ?? 1000000)
        .clamp(4096, 2000000);
    final reserved = ((json['reservedOutputTokens'] as num?)?.toInt() ?? 4096)
        .clamp(512, window - 1024);
    final history = ((json['maxHistoryMessages'] as num?)?.toInt() ?? 0).clamp(
      0,
      100000,
    );
    return ContextPrefs(
      enabled: json['enabled'] as bool? ?? true,
      inputLimitTokens: (json['inputLimitTokens'] as num?)?.toInt(),
      contextWindowTokens: window,
      reservedOutputTokens: reserved,
      maxHistoryMessages: history,
      maxOutputTokens: ((json['maxOutputTokens'] as num?)?.toInt() ?? 0).clamp(
        0,
        2000000,
      ),
    );
  }
}
