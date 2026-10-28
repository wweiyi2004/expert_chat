import 'package:path/path.dart' as p;
import 'dart:convert';
import 'workspace_host.dart';

/// Merge navigation groups only when both location and effective grants match.
String workspaceNavigationIdentity(DesktopWorkspace workspace) {
  final scopes =
      workspace.scopes
          .map(
            (s) => [s.name, workspacePathIdentity(s.path), s.access.wireValue],
          )
          .toList()
        ..sort((a, b) => a[0].compareTo(b[0]));
  return jsonEncode([workspacePathIdentity(workspace.root), scopes]);
}

/// Rust canonical paths on Windows use the extended-length prefix; Dart's
/// resolveSymbolicLinks may return the same directory without it.
String workspacePathIdentity(String path, {bool? windows}) {
  final useWindows = windows ?? p.style == p.Style.windows;
  if (!useWindows) return p.posix.normalize(path);
  var value = path.replaceAll('/', r'\');
  if (value.toLowerCase().startsWith(r'\\?\unc\')) {
    value = r'\\' + value.substring(8);
  } else if (value.startsWith(r'\\?\')) {
    value = value.substring(4);
  }
  return p.windows.normalize(value).toLowerCase();
}
