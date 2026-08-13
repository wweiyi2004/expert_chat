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
    this.uploadBaseUrl = '',
    this.authServiceUrl = '',
    this.oidcClientId = 'expert-chat',
    this.oidcRedirectUri = 'expertchat://auth/callback',
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
  final String uploadBaseUrl;
  final String authServiceUrl;
  final String oidcClientId;
  final String oidcRedirectUri;
  final String taskModel;
  final int taskPollSeconds;
  final int requestTimeoutSeconds;
  final bool capabilitiesDiscovered;
  final List<String> capabilities;
  final String? serverVersion;

  bool get isConfigured => enabled && normalizedBaseUrl.isNotEmpty;
  bool get authServiceConfigured =>
      normalizedAuthServiceUrl.isNotEmpty &&
      oidcClientId.trim().isNotEmpty &&
      Uri.tryParse(oidcRedirectUri.trim())?.scheme.isNotEmpty == true;

  String get normalizedBaseUrl {
    return _normalizeBaseUrl(baseUrl);
  }

  String get normalizedUploadBaseUrl => _normalizeBaseUrl(uploadBaseUrl);
  String get normalizedAuthServiceUrl => _normalizeBaseUrl(authServiceUrl);

  String get effectiveUploadBaseUrl {
    final upload = normalizedUploadBaseUrl;
    return upload.isEmpty ? normalizedBaseUrl : upload;
  }

  bool get hasDedicatedUploadBaseUrl {
    final upload = normalizedUploadBaseUrl;
    return upload.isNotEmpty && upload != normalizedBaseUrl;
  }

  static String _normalizeBaseUrl(String raw) {
    var value = raw.trim();
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
    String? uploadBaseUrl,
    String? authServiceUrl,
    String? oidcClientId,
    String? oidcRedirectUri,
    String? taskModel,
    int? taskPollSeconds,
    int? requestTimeoutSeconds,
    bool? capabilitiesDiscovered,
    List<String>? capabilities,
    Object? serverVersion = _gatewaySentinel,
  }) => GatewayConfig(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    uploadBaseUrl: uploadBaseUrl ?? this.uploadBaseUrl,
    authServiceUrl: authServiceUrl ?? this.authServiceUrl,
    oidcClientId: oidcClientId ?? this.oidcClientId,
    oidcRedirectUri: oidcRedirectUri ?? this.oidcRedirectUri,
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
    'uploadBaseUrl': uploadBaseUrl,
    'authServiceUrl': authServiceUrl,
    'oidcClientId': oidcClientId,
    'oidcRedirectUri': oidcRedirectUri,
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
    uploadBaseUrl:
        json['uploadBaseUrl'] as String? ??
        json['upload_base_url'] as String? ??
        '',
    authServiceUrl:
        json['authServiceUrl'] as String? ??
        json['auth_service_url'] as String? ??
        '',
    oidcClientId:
        json['oidcClientId'] as String? ??
        json['oidc_client_id'] as String? ??
        'expert-chat',
    oidcRedirectUri:
        json['oidcRedirectUri'] as String? ??
        json['oidc_redirect_uri'] as String? ??
        'expertchat://auth/callback',
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
  const GatewayConnection({
    required this.config,
    required this.apiToken,
    this.tokenProvider,
  });

  final GatewayConfig config;
  final String apiToken;
  final Future<String> Function()? tokenProvider;

  Future<String> resolveApiToken() async {
    final provider = tokenProvider;
    return provider == null ? apiToken : (await provider()).trim();
  }
}
