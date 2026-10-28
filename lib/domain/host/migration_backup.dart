import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../platform/paths_host.dart';
import '../../platform/atomic_file.dart';

/// Called only after exclusive ownership, before opening SQLite or migrating
/// preferences. Preserve the WAL with its database; never copy a live writer.
Future<void> preservePreHostData() async {
  final support = await getApplicationSupportDirectory();
  final marker = File(p.join(support.path, 'host', 'migration-backup.v1'));
  if (await marker.exists()) return;
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory(
    p.join(
      support.path,
      'host',
      'pre-host-${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  await directory.create(recursive: true);
  final sources = <String, File>{
    for (final name in [
      'shared_preferences.json',
      'conversations.json',
      'flutter_secure_storage.dat',
    ])
      name: File(p.join(support.path, name)),
    for (final suffix in ['', '-wal', '-shm'])
      'expert_chat.sqlite$suffix': File(
        p.join(documents.path, 'expert_chat.sqlite$suffix'),
      ),
  };
  final copied = <String>[];
  for (final entry in sources.entries) {
    if (await entry.value.exists()) {
      await entry.value.copy(p.join(directory.path, entry.key));
      copied.add(entry.key);
    }
  }
  await writeAtomic(
    File(p.join(directory.path, 'manifest.json')),
    utf8.encode(jsonEncode({'version': 1, 'files': copied})),
  );
  await writeAtomic(
    marker,
    utf8.encode(jsonEncode({'version': 1, 'directory': directory.path})),
  );
}
