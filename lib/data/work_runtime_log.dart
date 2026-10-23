import 'dart:convert';

enum WorkRuntimeLogLevel { info, warning, error }

/// Diagnostics only: callers must never pass prompts, tool arguments, file
/// contents, response bodies or full HTTP headers into a runtime log.
String sanitizeRuntimeLogText(
  String value, {
  Iterable<String> secrets = const [],
}) {
  var safe = value;
  for (final secret
      in secrets.where((s) => s.isNotEmpty).toList()
        ..sort((a, b) => b.length.compareTo(a.length))) {
    safe = safe.replaceAll(secret, '[redacted]');
  }
  safe = safe.replaceAll(
    RegExp(r'data:[^\s,]+;base64,[A-Za-z0-9+/=]+'),
    '[data omitted]',
  );
  safe = safe.replaceAll(
    RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|secret|cookie)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[redacted]',
  );
  safe = safe.replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{8,}'), '[redacted]');
  safe = safe.replaceAll(
    RegExp(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
    '[redacted]',
  );
  safe = safe.replaceAllMapped(RegExp(r'''https?://[^\s<>"']+'''), (m) {
    final uri = Uri.tryParse(m[0]!);
    return uri == null || uri.host.isEmpty
        ? '[endpoint]'
        : '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
  });
  safe = safe.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
  return safe.length <= 2048 ? safe : '${safe.substring(0, 2048)}…';
}

String? runtimeLogHost(String? endpoint) {
  if (endpoint == null || endpoint.isEmpty) return null;
  final uri = Uri.tryParse(endpoint);
  if (uri == null || uri.host.isEmpty) return null;
  return '${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
}

class WorkRuntimeLogEntry {
  const WorkRuntimeLogEntry({
    required this.id,
    required this.conversationId,
    required this.timestamp,
    required this.level,
    required this.phase,
    required this.status,
    this.taskId,
    this.requestId,
    this.toolCallId,
    this.toolName,
    this.model,
    this.host,
    this.detail,
    this.errorType,
    this.durationMs,
    this.httpStatus,
    this.timeoutSeconds,
  });
  final String id, conversationId, phase, status;
  final DateTime timestamp;
  final WorkRuntimeLogLevel level;
  final String? taskId,
      requestId,
      toolCallId,
      toolName,
      model,
      host,
      detail,
      errorType;
  final int? durationMs, httpStatus, timeoutSeconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'level': level.name,
    'phase': phase,
    'status': status,
    if (taskId != null) 'taskId': taskId,
    if (requestId != null) 'requestId': requestId,
    if (toolCallId != null) 'toolCallId': toolCallId,
    if (toolName != null) 'toolName': toolName,
    if (model != null) 'model': model,
    if (host != null) 'host': host,
    if (detail != null) 'detail': detail,
    if (errorType != null) 'errorType': errorType,
    if (durationMs != null) 'durationMs': durationMs,
    if (httpStatus != null) 'httpStatus': httpStatus,
    if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
  };

  factory WorkRuntimeLogEntry.fromJson(Map<String, dynamic> json) {
    String text(String key) => sanitizeRuntimeLogText(json[key] as String);
    String? optional(String key) => json[key] is String ? text(key) : null;
    return WorkRuntimeLogEntry(
      id: text('id'),
      conversationId: text('conversationId'),
      timestamp: DateTime.parse(json['timestamp'] as String),
      level: WorkRuntimeLogLevel.values.byName(json['level'] as String),
      phase: text('phase'),
      status: text('status'),
      taskId: optional('taskId'),
      requestId: optional('requestId'),
      toolCallId: optional('toolCallId'),
      toolName: optional('toolName'),
      model: optional('model'),
      host: optional('host'),
      detail: optional('detail'),
      errorType: optional('errorType'),
      durationMs: (json['durationMs'] as num?)?.toInt(),
      httpStatus: (json['httpStatus'] as num?)?.toInt(),
      timeoutSeconds: (json['timeoutSeconds'] as num?)?.toInt(),
    );
  }
}

List<WorkRuntimeLogEntry> retainRuntimeLogs(
  Iterable<WorkRuntimeLogEntry> entries, {
  required DateTime now,
  int perConversation = 200,
  int total = 1500,
  int maxBytes = 1024 * 1024,
  Duration age = const Duration(days: 7),
}) {
  final ordered =
      entries
          .where(
            (e) =>
                !e.timestamp.isBefore(now.subtract(age)) &&
                !e.timestamp.isAfter(now.add(const Duration(days: 1))),
          )
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final counts = <String, int>{};
  final kept = <WorkRuntimeLogEntry>[];
  var bytes = 2;
  for (final entry in ordered.reversed) {
    if (kept.length >= total) break;
    if ((counts[entry.conversationId] ?? 0) >= perConversation) continue;
    final size = utf8.encode(jsonEncode(entry.toJson())).length + 1;
    if (bytes + size > maxBytes) continue;
    bytes += size;
    counts.update(entry.conversationId, (n) => n + 1, ifAbsent: () => 1);
    kept.add(entry);
  }
  return List.unmodifiable(kept.reversed);
}
