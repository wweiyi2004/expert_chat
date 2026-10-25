import 'dart:convert';
import 'package:path/path.dart' as p;

/// Comparison identity only. Never substitute these normalized paths for the
/// captured target/scope used by the permissioned execution session.
({String authority, String physical, String? rootRelative})? reviewPhysicalPath(
  String target,
  String scope,
  String path,
) {
  try {
    final data = jsonDecode(target) as Map;
    final rawRoot = data['root'] as String;
    final windows =
        data['kind'] == 'local' &&
        (RegExp(r'^[a-zA-Z]:').hasMatch(rawRoot) || rawRoot.startsWith(r'\\'));
    String normalize(String value) {
      var result = value.replaceAll(r'\', '/');
      if (result.startsWith('//?/UNC/')) {
        result = '//${result.substring(8)}';
      } else if (result.startsWith('//?/')) {
        result = result.substring(4);
      }
      result = p.posix.normalize(result);
      return windows ? result.toLowerCase() : result;
    }

    final root = normalize(rawRoot);
    final scopePath =
        (data['scopes'] as Map?)?[scope] ?? (scope == 'root' ? rawRoot : null);
    if (scopePath is! String) return null;
    final mapped = normalize(scopePath);
    final physical = normalize(
      p.posix.join(
        mapped,
        '${data['pathPrefix'] ?? ''}',
        path.replaceAll(r'\', '/'),
      ),
    );
    final relative = p.posix.equals(root, physical)
        ? '.'
        : p.posix.isWithin(root, physical)
        ? p.posix.relative(physical, from: root)
        : null;
    return (
      authority: jsonEncode({
        'kind': data['kind'],
        'host': data['workspaceId'] ?? data['profileId'],
        'root': root,
      }),
      physical: physical,
      rootRelative: relative,
    );
  } catch (_) {
    return null;
  }
}
