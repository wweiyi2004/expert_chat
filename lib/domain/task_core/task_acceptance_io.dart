import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'task_acceptance.dart';

/// Called by the host at delivery/acceptance, never by an untrusted model claim.
Future<void> observeAcceptanceArtifacts(
  TaskAcceptance task,
  String root,
) async {
  final base = await Directory(root).resolveSymbolicLinks();
  for (final path in task.criteria.artifactPaths) {
    final candidate = p.normalize(
      p.isAbsolute(path) ? path : p.join(base, path),
    );
    if (!(p.equals(base, candidate) || p.isWithin(base, candidate))) {
      throw ArgumentError('Artifact outside workspace');
    }
    final file = File(candidate);
    if (!await file.exists()) {
      task.recordArtifact(
        path: path,
        present: false,
        sha256: '',
        provenance: 'host:file:$candidate',
      );
      continue;
    }
    final resolved = await file.resolveSymbolicLinks();
    if (!p.isWithin(base, resolved)) {
      throw ArgumentError('Artifact symlink outside workspace');
    }
    final digest = await sha256.bind(file.openRead()).first;
    task.recordArtifact(
      path: path,
      present: true,
      sha256: digest.toString(),
      provenance: 'host:file:$resolved',
    );
  }
}
