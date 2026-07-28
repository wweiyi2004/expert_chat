import 'dart:convert';

/// Non-secret SSH host profile. Passwords / private keys live only in
/// [flutter_secure_storage], never here.
enum SshAuthType { password, privateKey }

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
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthType authType;

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
  }) => SshProfile(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    authType: authType ?? this.authType,
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
    return SshProfile(
      id: id,
      name: ((json['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (json['name'] as String).trim()
          : host,
      host: host,
      port: (json['port'] as num?)?.toInt() ?? 22,
      username: username,
      authType: auth,
      trustedHostKeyFingerprint: (json['trustedHostKeyFingerprint'] as String?)
          ?.trim(),
      lastUsedAt: lastUsed,
    );
  }

  static List<SshProfile> listFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list)
          if (e is Map<String, dynamic>)
            ?fromJson(e)
          else if (e is Map)
            ?fromJson(Map<String, dynamic>.from(e)),
      ].whereType<SshProfile>().toList();
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
