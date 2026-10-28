import 'dart:convert';

/// Non-secret SSH host profile. Passwords / private keys live only in
/// [flutter_secure_storage], never here.
enum SshAuthType { password, privateKey }

/// A fixed TCP RemoteForward: remote listener -> local destination.
class SshRemoteForward {
  const SshRemoteForward({
    this.bindHost = 'localhost',
    required this.bindPort,
    required this.targetHost,
    required this.targetPort,
  });
  final String bindHost, targetHost;
  final int bindPort, targetPort;
  static String _address(String host) => host.contains(':') ? '[$host]' : host;
  String get configLine =>
      '${bindHost == 'localhost' ? '' : '${_address(bindHost)}:'}$bindPort ${_address(targetHost)}:$targetPort';
  Map<String, dynamic> toJson() => {
    'bindHost': bindHost,
    'bindPort': bindPort,
    'targetHost': targetHost,
    'targetPort': targetPort,
  };
  factory SshRemoteForward.fromJson(Map<String, dynamic> json) => parse(
    '${_address(json['bindHost'] as String? ?? 'localhost')}:${json['bindPort']} ${_address(json['targetHost'] as String)}:${json['targetPort']}',
  );
  static SshRemoteForward parse(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.first.toLowerCase() == 'remoteforward') parts.removeAt(0);
    Never invalid() => throw const FormatException(
      'RemoteForward 格式：10808 127.0.0.1:7890；IPv6 地址使用方括号',
    );
    if (parts.length != 2) invalid();
    (String, int) endpoint(String value, {bool listener = false}) {
      if (listener && RegExp(r'^\d+$').hasMatch(value)) {
        return ('localhost', int.parse(value));
      }
      final match = RegExp(
        r'^(?:\[([^\]]+)\]|([^:\s]+)):(\d+)$',
      ).firstMatch(value);
      if (match == null) invalid();
      final host = match.group(1) ?? match.group(2)!;
      if (host.isEmpty || RegExp(r'[\s\x00-\x1f\x7f/\\]').hasMatch(host)) {
        invalid();
      }
      return (host, int.parse(match.group(3)!));
    }

    final listen = endpoint(parts[0], listener: true),
        target = endpoint(parts[1]);
    if (listen.$2 < 1 ||
        listen.$2 > 65535 ||
        target.$2 < 1 ||
        target.$2 > 65535) {
      invalid();
    }
    return SshRemoteForward(
      bindHost: listen.$1,
      bindPort: listen.$2,
      targetHost: target.$1,
      targetPort: target.$2,
    );
  }

  static List<SshRemoteForward> parseLines(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (lines.length > 16 || text.length > 8192) {
      throw const FormatException('最多设置 16 条 RemoteForward');
    }
    final values = lines.map(parse).toList();
    final ports = <String>{};
    for (final value in values) {
      if (!ports.add('${value.bindHost}:${value.bindPort}')) {
        throw const FormatException('RemoteForward 监听地址和端口重复');
      }
    }
    return List.unmodifiable(values);
  }
}

class SshProfile {
  const SshProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authType = SshAuthType.password,
    this.trustedHostKeyFingerprint,
    this.lastUsedAt,
    this.remoteForwards = const [],
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthType authType;
  final List<SshRemoteForward> remoteForwards;
  String get remoteForwardText =>
      remoteForwards.map((f) => f.configLine).join('\n');

  /// SHA-256 fingerprint of the server host key once the user trusts it.
  final String? trustedHostKeyFingerprint;
  final DateTime? lastUsedAt;

  SshProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthType? authType,
    Object? trustedHostKeyFingerprint = _sentinel,
    Object? lastUsedAt = _sentinel,
    List<SshRemoteForward>? remoteForwards,
  }) => SshProfile(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    authType: authType ?? this.authType,
    remoteForwards: remoteForwards ?? this.remoteForwards,
    trustedHostKeyFingerprint: identical(trustedHostKeyFingerprint, _sentinel)
        ? this.trustedHostKeyFingerprint
        : trustedHostKeyFingerprint as String?,
    lastUsedAt: identical(lastUsedAt, _sentinel)
        ? this.lastUsedAt
        : lastUsedAt as DateTime?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authType': authType.name,
    if (remoteForwards.isNotEmpty)
      'remoteForwards': remoteForwards.map((f) => f.toJson()).toList(),
    if (trustedHostKeyFingerprint != null)
      'trustedHostKeyFingerprint': trustedHostKeyFingerprint,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
  };

  static SshProfile? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = (json['id'] as String?)?.trim() ?? '';
    final host = (json['host'] as String?)?.trim() ?? '';
    final username = (json['username'] as String?)?.trim() ?? '';
    if (id.isEmpty || host.isEmpty || username.isEmpty) return null;
    final authRaw = (json['authType'] as String?) ?? SshAuthType.password.name;
    final auth = SshAuthType.values.firstWhere(
      (e) => e.name == authRaw,
      orElse: () => SshAuthType.password,
    );
    DateTime? lastUsed;
    final lastRaw = json['lastUsedAt'] as String?;
    if (lastRaw != null) lastUsed = DateTime.tryParse(lastRaw);
    final rawForwards = json['remoteForwards'] as List? ?? const [];
    if (rawForwards.length > 16) {
      throw const FormatException('最多设置 16 条 RemoteForward');
    }
    final forwards = SshRemoteForward.parseLines(
      rawForwards
          .map(
            (f) => SshRemoteForward.fromJson(
              Map<String, dynamic>.from(f as Map),
            ).configLine,
          )
          .join('\n'),
    );
    return SshProfile(
      id: id,
      name: ((json['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (json['name'] as String).trim()
          : host,
      host: host,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: username,
      authType: auth,
      remoteForwards: forwards,
      trustedHostKeyFingerprint: (json['trustedHostKeyFingerprint'] as String?)
          ?.trim(),
      lastUsedAt: lastUsed,
    );
  }

  static List<SshProfile> listFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final result = <SshProfile>[];
      for (final e in list) {
        // A single corrupt entry (e.g. wrong field type) must not wipe out
        // the whole list: skip it and keep the healthy profiles.
        try {
          if (e is Map<String, dynamic>) {
            final profile = fromJson(e);
            if (profile != null) result.add(profile);
          } else if (e is Map) {
            final profile = fromJson(Map<String, dynamic>.from(e));
            if (profile != null) result.add(profile);
          }
        } catch (_) {
          // Skip this corrupt entry; keep parsing the rest.
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static String listToJson(List<SshProfile> profiles) =>
      jsonEncode(profiles.map((p) => p.toJson()).toList());

  static const _sentinel = Object();
}

class TmuxSessionInfo {
  const TmuxSessionInfo({
    required this.name,
    required this.attached,
    required this.windows,
  });

  final String name;
  final int attached;
  final int windows;
}
