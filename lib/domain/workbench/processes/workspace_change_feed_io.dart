import 'dart:io';
import 'package:path/path.dart' as p;

Stream<String> watchWorkspaceChanges(String root) async* {
  final directory = Directory(root);
  if (!await directory.exists()) throw StateError('监控目录不存在');
  final canonical = await directory.resolveSymbolicLinks();
  await for (final event in Directory(canonical).watch(recursive: true)) {
    final relative = p
        .relative(event.path, from: canonical)
        .replaceAll('\\', '/');
    if (relative.startsWith('../') || p.isAbsolute(relative)) continue;
    yield relative;
  }
}
