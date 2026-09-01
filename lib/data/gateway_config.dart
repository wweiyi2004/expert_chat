const _gatewaySentinel = Object();

abstract final class GatewayCapabilityIds {
  static const longTasks = 'long_tasks';
  static const documentEdit = 'document_edit';
  static const documentConvert = 'document_convert';
}

class DiscoveredMcpTool {
  const DiscoveredMcpTool({
    required this.name,
    this.description = '',
    this.inputSchema = const <String, dynamic>{},
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };

  factory DiscoveredMcpTool.fromJson(Map<String, dynamic> json) =>
      DiscoveredMcpTool(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        inputSchema: json['inputSchema'] is Map
            ? Map<String, dynamic>.from(json['inputSchema'] as Map)
            : const <String, dynamic>{},
      );
}

/// User-added Streamable HTTP MCP server, separate from the document MCP.
class CustomMcpServer {
  const CustomMcpServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.enabled = true,
    this.toolsDiscovered = false,
    this.tools = const <DiscoveredMcpTool>[],
    this.serverVersion,
    this.lastError,
  });

  final String id;
  final String name;
  final String baseUrl;
  final bool enabled;
  final bool toolsDiscovered;
  final List<DiscoveredMcpTool> tools;
  final String? serverVersion;
  final String? lastError;

  String get normalizedBaseUrl => GatewayConfig.normalizeBaseUrl(baseUrl);

  bool get isConfigured => normalizedBaseUrl.isNotEmpty;

  /// Stable prefix used when a tool name collides.
  String get slug {
    final fromName = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (fromName.isNotEmpty) return fromName;
    final fromId = id
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return fromId.isEmpty ? 'mcp' : fromId;
  }

  CustomMcpServer copyWith({
    String? name,
    String? baseUrl,
    bool? enabled,
    bool? toolsDiscovered,
    List<DiscoveredMcpTool>? tools,
    Object? serverVersion = _gatewaySentinel,
    Object? lastError = _gatewaySentinel,
  }) => CustomMcpServer(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    enabled: enabled ?? this.enabled,
    toolsDiscovered: toolsDiscovered ?? this.toolsDiscovered,
    tools: tools ?? this.tools,
    serverVersion: identical(serverVersion, _gatewaySentinel)
        ? this.serverVersion
        : serverVersion as String?,
    lastError: identical(lastError, _gatewaySentinel)
        ? this.lastError
        : lastError as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'enabled': enabled,
    'toolsDiscovered': toolsDiscovered,
    'tools': [for (final tool in tools) tool.toJson()],
    if (serverVersion != null) 'serverVersion': serverVersion,
    if (lastError != null) 'lastError': lastError,
  };

  factory CustomMcpServer.fromJson(Map<String, dynamic> json) =>
      CustomMcpServer(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        baseUrl: json['baseUrl']?.toString() ?? '',
        enabled: json['enabled'] as bool? ?? true,
        toolsDiscovered: json['toolsDiscovered'] as bool? ?? false,
        tools: [
          for (final raw in json['tools'] as List<dynamic>? ?? const [])
            if (raw is Map)
              DiscoveredMcpTool.fromJson(Map<String, dynamic>.from(raw)),
        ].where((tool) => tool.name.isNotEmpty).toList(),
        serverVersion: json['serverVersion']?.toString(),
        lastError: json['lastError']?.toString(),
      );
}

/// Persisted server connection settings.
///
/// The class name is retained for storage compatibility; the active document
/// path now connects to the standalone MCP Server and discovers MCP Tools.
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
    this.mcpTools = const <DiscoveredMcpTool>[],
    this.serverVersion,
    this.customMcpServers = const <CustomMcpServer>[],
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
  final List<DiscoveredMcpTool> mcpTools;
  final String? serverVersion;
  final List<CustomMcpServer> customMcpServers;

  bool get isConfigured => enabled && normalizedBaseUrl.isNotEmpty;
  bool get authServiceConfigured =>
      normalizedAuthServiceUrl.isNotEmpty &&
      oidcClientId.trim().isNotEmpty &&
      Uri.tryParse(oidcRedirectUri.trim())?.scheme.isNotEmpty == true;

  String get normalizedBaseUrl => normalizeBaseUrl(baseUrl);

  String get normalizedUploadBaseUrl => normalizeBaseUrl(uploadBaseUrl);
  String get normalizedAuthServiceUrl => normalizeBaseUrl(authServiceUrl);

  String get effectiveUploadBaseUrl {
    final upload = normalizedUploadBaseUrl;
    return upload.isEmpty ? normalizedBaseUrl : upload;
  }

  bool get hasDedicatedUploadBaseUrl {
    final upload = normalizedUploadBaseUrl;
    return upload.isNotEmpty && upload != normalizedBaseUrl;
  }

  static String normalizeBaseUrl(String raw) {
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

  /// MCP discovery is authoritative. Do not expose network tools until the
  /// server has returned a successful tools/list result.
  bool supports(String capabilityId) =>
      isConfigured &&
      capabilitiesDiscovered &&
      capabilities.contains(capabilityId);

  GatewayConnection connectionForCustom(CustomMcpServer server, String token) =>
      GatewayConnection(
        config: GatewayConfig(
          enabled: true,
          baseUrl: server.baseUrl,
          requestTimeoutSeconds: requestTimeoutSeconds,
        ),
        apiToken: token,
      );

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
    List<DiscoveredMcpTool>? mcpTools,
    Object? serverVersion = _gatewaySentinel,
    List<CustomMcpServer>? customMcpServers,
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
    mcpTools: mcpTools ?? this.mcpTools,
    serverVersion: identical(serverVersion, _gatewaySentinel)
        ? this.serverVersion
        : serverVersion as String?,
    customMcpServers: customMcpServers ?? this.customMcpServers,
  );

  GatewayConfig clearDiscovery() => copyWith(
    capabilitiesDiscovered: false,
    capabilities: const [],
    mcpTools: const [],
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
    'mcpTools': [for (final tool in mcpTools) tool.toJson()],
    if (serverVersion != null) 'serverVersion': serverVersion,
    'customMcpServers': [
      for (final server in customMcpServers)
        if (server.id.isNotEmpty) server.toJson(),
    ],
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
    mcpTools: [
      for (final raw in json['mcpTools'] as List<dynamic>? ?? const [])
        if (raw is Map)
          DiscoveredMcpTool.fromJson(Map<String, dynamic>.from(raw)),
    ].where((tool) => tool.name.isNotEmpty).toList(),
    serverVersion: json['serverVersion'] as String?,
    customMcpServers: [
      for (final raw in json['customMcpServers'] as List<dynamic>? ?? const [])
        if (raw is Map)
          CustomMcpServer.fromJson(Map<String, dynamic>.from(raw)),
    ].where((server) => server.id.isNotEmpty).toList(),
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
