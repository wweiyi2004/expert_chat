import 'dart:convert';

import 'media_api_config.dart';

/// Portable API / settings snapshot for moving a fill-in config between devices.
///
/// The file contains secrets (API keys, gateway tokens). Keep exports out of
/// git — see `.gitignore` (`expert-chat-settings.json`, `config/*.json`).
class SettingsBundle {
  static const formatId = 'expert-chat-settings';
  static const currentVersion = 1;
  static const fileName = 'expert-chat-settings.json';
  static const maxBytes = 1024 * 1024;

  static String encode(Map<String, dynamic> payload, {DateTime? exportedAt}) =>
      const JsonEncoder.withIndent('  ').convert({
        'format': formatId,
        'version': currentVersion,
        'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
        ...payload,
      });

  /// UTF-8 text with an optional BOM (Windows Notepad re-saves add one).
  static String decodeUtf8(List<int> bytes) {
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }
    try {
      return utf8.decode(data);
    } on FormatException {
      throw const SettingsBundleException('配置文件不是有效的 UTF-8 文本。');
    }
  }

  static Map<String, dynamic> decode(String raw) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const SettingsBundleException('配置文件不是有效的 JSON。');
    }
    final map = asMap(decoded);
    if (map == null) {
      throw const SettingsBundleException('配置文件格式不正确。');
    }
    if (map['format']?.toString() != formatId) {
      throw const SettingsBundleException('这不是 Expert Chat 的配置文件。');
    }
    final version = (map['version'] as num?)?.toInt() ?? 0;
    if (version < 1) {
      throw const SettingsBundleException('配置文件缺少版本号。');
    }
    if (version > currentVersion) {
      throw SettingsBundleException('配置文件版本 $version 过新，请升级应用后再导入。');
    }
    return map;
  }

  static Map<String, dynamic>? asMap(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  static Map<String, dynamic> mediaToJson(
    MediaApiConfig config,
    String apiKey,
  ) {
    final json = config.toJson();
    json.remove('voiceClonePath');
    json['apiKey'] = apiKey;
    return json;
  }

  static ({MediaApiConfig config, String apiKey})? mediaFromJson(Object? raw) {
    final json = asMap(raw);
    if (json == null) return null;
    json['voiceClonePath'] = '';
    return (
      config: MediaApiConfig.fromJson(json),
      apiKey: json['apiKey']?.toString() ?? '',
    );
  }
}

class SettingsBundleException implements Exception {
  const SettingsBundleException(this.message);
  final String message;

  @override
  String toString() => message;
}
