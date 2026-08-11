const _gatewaySentinel = Object();

abstract final class GatewayCapabilityIds {
  static const longTasks = 'long_tasks';
  static const documentEdit = 'document_edit';
  static const documentConvert = 'document_convert';
}

/// The app has exactly one Gateway connection. Capability-specific settings
/// live here without creating another URL/token pair.
class GatewayConfig {
  const GatewayConfig({
    this.enabled = false,
    this.baseUrl = 'http://127.0.0.1:8790',
    this.taskModel = '',
    this.taskPollSeconds = 2,
    this.requestTimeoutSeconds = 120,
    this.capabilitiesDiscovered = false,
    this.capabilities = const <String>[],
    this.serverVersion,
  });

  static const minTaskPollSeconds = 1;
  static const maxTaskPollSeconds = 15;
  static const minRequestTimeoutSeconds = 30;
  static const maxRequestTimeoutSeconds = 600;

  final bool enabled;
  final String baseUrl;
  final String taskModel;
  final int taskPollSeconds;
  final int requestTimeoutSeconds;
  final bool capabilitiesDiscovered;
  final List<String> capabilities;
  final String? serverVersion;

  bool get isConfigured => enabled && normalizedBaseUrl.isNotEmpty;

  String get normalizedBaseUrl {
    var value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  Duration get requestTimeout => Duration(
    seconds: requestTimeoutSeconds.clamp(
      minRequestTimeoutSeconds,
      maxRequestTimeoutSeconds,
    ),
  );

  /// Before the first discovery, stay compatible with a migrated installation.
  /// Once discovery succeeds, the server manifest becomes authoritative.
  bool supports(String capabilityId) =>
      isConfigured &&
      (!capabilitiesDiscovered || capabilities.contains(capabilityId));

  GatewayConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? taskModel,
    int? taskPollSeconds,
    int? requestTimeoutSeconds,
    bool? capabilitiesDiscovered,
    List<String>? capabilities,
    Object? serverVersion = _gatewaySentinel,
  }) => GatewayConfig(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    taskModel: taskModel ?? this.taskModel,
    taskPollSeconds: (taskPollSeconds ?? this.taskPollSeconds).clamp(
      minTaskPollSeconds,
      maxTaskPollSeconds,
    ),
    requestTimeoutSeconds: (requestTimeoutSeconds ?? this.requestTimeoutSeconds)
        .clamp(minRequestTimeoutSeconds, maxRequestTimeoutSeconds),
    capabilitiesDiscovered:
        capabilitiesDiscovered ?? this.capabilitiesDiscovered,
    capabilities: capabilities ?? this.capabilities,
    serverVersion: identical(serverVersion, _gatewaySentinel)
        ? this.serverVersion
        : serverVersion as String?,
  );

  GatewayConfig clearDiscovery() => copyWith(
    capabilitiesDiscovered: false,
    capabilities: const [],
    serverVersion: null,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'baseUrl': baseUrl,
    'taskModel': taskModel,
    'taskPollSeconds': taskPollSeconds,
    'requestTimeoutSeconds': requestTimeoutSeconds,
    'capabilitiesDiscovered': capabilitiesDiscovered,
    'capabilities': capabilities,
    if (serverVersion != null) 'serverVersion': serverVersion,
  };

  factory GatewayConfig.fromJson(Map<String, dynamic> json) => GatewayConfig(
    enabled: json['enabled'] as bool? ?? false,
    baseUrl: json['baseUrl'] as String? ?? 'http://127.0.0.1:8790',
    taskModel: json['taskModel'] as String? ?? '',
    taskPollSeconds: ((json['taskPollSeconds'] as num?)?.toInt() ?? 2).clamp(
      minTaskPollSeconds,
      maxTaskPollSeconds,
    ),
    requestTimeoutSeconds:
        ((json['requestTimeoutSeconds'] as num?)?.toInt() ?? 120).clamp(
          minRequestTimeoutSeconds,
          maxRequestTimeoutSeconds,
        ),
    capabilitiesDiscovered: json['capabilitiesDiscovered'] as bool? ?? false,
    capabilities: (json['capabilities'] as List<dynamic>? ?? const [])
        .map((value) => value.toString())
        .where((value) => value.trim().isNotEmpty)
        .toSet()
        .toList(),
    serverVersion: json['serverVersion'] as String?,
  );
}

class GatewayConnection {
  const GatewayConnection({required this.config, required this.apiToken});

  final GatewayConfig config;
  final String apiToken;
}
