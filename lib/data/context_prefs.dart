class ContextPrefs {
  const ContextPrefs({
    this.enabled = true,
    this.contextWindowTokens = 256000,
    this.reservedOutputTokens = 4096,
    this.maxHistoryMessages = 24,
  });

  final bool enabled;

  /// Total context window advertised by the selected model.
  final int contextWindowTokens;

  /// Space kept free for the model's response.
  final int reservedOutputTokens;

  /// Maximum number of non-system messages sent from the active branch.
  final int maxHistoryMessages;

  int get inputBudgetTokens => (contextWindowTokens - reservedOutputTokens)
      .clamp(1024, contextWindowTokens);

  ContextPrefs copyWith({
    bool? enabled,
    int? contextWindowTokens,
    int? reservedOutputTokens,
    int? maxHistoryMessages,
  }) => ContextPrefs(
    enabled: enabled ?? this.enabled,
    contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    reservedOutputTokens: reservedOutputTokens ?? this.reservedOutputTokens,
    maxHistoryMessages: maxHistoryMessages ?? this.maxHistoryMessages,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'contextWindowTokens': contextWindowTokens,
    'reservedOutputTokens': reservedOutputTokens,
    'maxHistoryMessages': maxHistoryMessages,
  };

  factory ContextPrefs.fromJson(Map<String, dynamic> json) {
    final window = ((json['contextWindowTokens'] as num?)?.toInt() ?? 256000)
        .clamp(4096, 2000000);
    final reserved = ((json['reservedOutputTokens'] as num?)?.toInt() ?? 4096)
        .clamp(512, window - 1024);
    // Must stay inside the settings Slider's 4..64 range; values outside it
    // would trip the Slider's value assertion when the page opens.
    final history = ((json['maxHistoryMessages'] as num?)?.toInt() ?? 24).clamp(
      4,
      64,
    );
    return ContextPrefs(
      enabled: json['enabled'] as bool? ?? true,
      contextWindowTokens: window,
      reservedOutputTokens: reserved,
      maxHistoryMessages: history,
    );
  }
}
