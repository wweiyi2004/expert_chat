class BridgeFailure implements Exception {
  const BridgeFailure(this.code, this.message);
  final String code, message;
}

const terminalWorkbenchQueryTopics = {
  'wb.jobs',
  'wb.job',
  'wb.sessions',
  'wb.session',
  'wb.agent.poll',
  'wb.files',
  'wb.file.open',
  'wb.git',
  'wb.git.diff',
  'wb.automation',
  'wb.automation.status',
  'wb.automation.remote',
  'wb.backup',
  'wb.update',
  'wb.voice',
  'wb.media',
  'wb.media.text',
};

abstract interface class BridgeBackend {
  List<String> get capabilities;
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> params,
  );
  Future<Map<String, Object?>> snapshot(String? session);
}

abstract interface class BridgeClientLifecycle {
  Future<void> releaseClient(String scope);
  Future<void> selectClientSession(String scope, String session);
}

abstract interface class WindowTaskLifecycle {
  void registerWindowClient(String scope);
  Future<Map<String, Object?>> snapshotForWindow(String scope, String? session);
}

/// A persistent execution host survives closing an individual TUI connection.
abstract interface class PersistentBridgeHost {
  String get hostVersion;
}

abstract interface class PrivilegedBridgeBackend {
  bool isPrivilegedMethod(String method);
  int get revision;
}

abstract interface class BridgeGuiLifecycle {
  void registerGuiClient(String scope);
}

String requiredString(Map<String, dynamic> params, String name) {
  final value = params[name];
  if (value is! String || value.trim().isEmpty) {
    throw BridgeFailure('invalid_params', '缺少 $name');
  }
  return value;
}

/// Redact known configured credentials even when a tool's output echoes one.
Object? redactBridgeValue(Object? value, Iterable<String> secrets) {
  if (value is String) {
    var result = value;
    for (final secret in secrets.where((s) => s.length >= 6)) {
      result = result.replaceAll(secret, '[REDACTED]');
    }
    return result.replaceAll(
      RegExp(r'(bearer\s+)[A-Za-z0-9_.~+/=-]{12,}', caseSensitive: false),
      'Bearer [REDACTED]',
    );
  }
  if (value is List) {
    return value.map((v) => redactBridgeValue(v, secrets)).toList();
  }
  if (value is Map) {
    return {
      for (final e in value.entries) e.key: redactBridgeValue(e.value, secrets),
    };
  }
  return value;
}
