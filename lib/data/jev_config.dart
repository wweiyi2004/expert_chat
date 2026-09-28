import 'dart:convert';

/// Non-secret settings. The key lives separately in secure storage.
class JevConfig {
  const JevConfig({
    this.enabled = false,
    this.model = 'jev-latest',
    this.minConfidence = 0.6,
  });

  final bool enabled;
  final String model;
  final double minConfidence;

  JevConfig copyWith({bool? enabled, String? model, double? minConfidence}) =>
      JevConfig(
        enabled: enabled ?? this.enabled,
        model: model ?? this.model,
        minConfidence: minConfidence ?? this.minConfidence,
      ).normalized();

  JevConfig normalized() => JevConfig(
    enabled: enabled,
    model: model.trim().isEmpty ? 'jev-latest' : model.trim(),
    minConfidence: minConfidence.isFinite ? minConfidence.clamp(0.0, 1.0) : 0.6,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'model': model,
    'minConfidence': minConfidence,
  };

  factory JevConfig.fromJson(Map<String, dynamic> json) => JevConfig(
    enabled: json['enabled'] == true,
    model: json['model'] is String ? json['model'] as String : 'jev-latest',
    minConfidence: json['minConfidence'] is num
        ? (json['minConfidence'] as num).toDouble()
        : 0.6,
  ).normalized();

  static JevConfig decode(String? raw) {
    try {
      final value = jsonDecode(raw ?? '');
      if (value is Map<String, dynamic>) return JevConfig.fromJson(value);
    } catch (_) {
      // A missing/corrupt preference must leave existing routing usable.
    }
    return const JevConfig();
  }
}
