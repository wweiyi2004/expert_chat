/// Optional remote document-edit service (Linux FastAPI).
///
/// API token is stored separately in secure storage — not in this object.
class DocumentServiceConfig {
  const DocumentServiceConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.timeoutSeconds = 120,
  });

  final bool enabled;

  /// e.g. `https://doc.example.com` (no trailing slash required).
  final String baseUrl;

  final int timeoutSeconds;

  static const minTimeoutSeconds = 30;
  static const maxTimeoutSeconds = 600;
  static const defaultTimeoutSeconds = 120;

  bool isConfiguredWith(String apiToken) =>
      enabled &&
      baseUrl.trim().isNotEmpty &&
      apiToken.trim().isNotEmpty;

  Duration get timeout {
    final s = timeoutSeconds.clamp(minTimeoutSeconds, maxTimeoutSeconds);
    return Duration(seconds: s);
  }

  String get normalizedBaseUrl {
    var u = baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  DocumentServiceConfig copyWith({
    bool? enabled,
    String? baseUrl,
    int? timeoutSeconds,
  }) => DocumentServiceConfig(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'baseUrl': baseUrl,
    'timeoutSeconds': timeoutSeconds,
  };

  factory DocumentServiceConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DocumentServiceConfig();
    final timeout = (json['timeoutSeconds'] as num?)?.toInt() ??
        defaultTimeoutSeconds;
    return DocumentServiceConfig(
      enabled: json['enabled'] as bool? ?? false,
      baseUrl: json['baseUrl'] as String? ?? '',
      timeoutSeconds: timeout.clamp(minTimeoutSeconds, maxTimeoutSeconds),
    );
  }
}
