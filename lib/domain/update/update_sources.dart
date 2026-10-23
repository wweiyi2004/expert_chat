import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// URL templates refer to real published assets, never an assumed mirror.
class UpdateSource {
  const UpdateSource({required this.name, required this.template});
  final String name;
  final String template;
  String? get releaseApi {
    final uri = Uri.tryParse(template);
    if (uri?.host != 'gitee.com' ||
        uri!.pathSegments.length < 3 ||
        uri.pathSegments[2] != 'releases') {
      return null;
    }
    return 'https://gitee.com/api/v5/repos/${Uri.encodeComponent(uri.pathSegments[0])}/'
        '${Uri.encodeComponent(uri.pathSegments[1])}/releases/latest';
  }

  String resolve({
    required String tag,
    required String fileName,
    required String originalUrl,
  }) => template
      .replaceAll('{tag}', Uri.encodeComponent(tag))
      .replaceAll('{file}', Uri.encodeComponent(fileName))
      .replaceAll('{url}', originalUrl);
  Map<String, dynamic> toJson() => {'name': name, 'template': template};

  static String? validate(String template) {
    final sample = template
        .replaceAll('{tag}', 'v1.0.0')
        .replaceAll('{file}', 'app.apk')
        .replaceAll(
          '{url}',
          'https://github.com/example/app/releases/download/v1.0.0/app.apk',
        );
    final uri = Uri.tryParse(sample);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return '请输入 HTTPS 下载地址';
    }
    if (!template.contains('{file}') && !template.contains('{url}')) {
      return '地址需要包含 {file} 或 {url}';
    }
    if (template.contains('{file}') && !template.contains('{tag}')) {
      return '文件镜像还需要 {tag}，以区分不同版本';
    }
    return null;
  }
}

class UpdateSources {
  static const key = 'updateSourcesV1';
  static const preferredKey = 'updatePreferredSourceV1';
  static List<UpdateSource> read(SharedPreferences prefs) {
    try {
      return [
        for (final item in jsonDecode(prefs.getString(key) ?? '[]') as List)
          if (item is Map &&
              item['name'] is String &&
              item['template'] is String &&
              UpdateSource.validate(item['template'] as String) == null)
            UpdateSource(
              name: item['name'] as String,
              template: item['template'] as String,
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(
    SharedPreferences prefs,
    List<UpdateSource> sources,
  ) async {
    await prefs.setString(
      key,
      jsonEncode([for (final s in sources) s.toJson()]),
    );
  }
}
