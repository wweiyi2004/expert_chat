import 'dart:convert';
import 'dart:io';
import '../platform/paths.dart';

/// Written BEFORE staging files or touching external memory/preferences.
/// A DB commit marker determines whether startup rolls back the auxiliary data.
class BackupJournal {
  BackupJournal({this.pathOverride});
  final String? pathOverride;
  Future<File> get _file async => File(
    pathOverride ??
        '${(await getApplicationSupportDirectory()).path}/restore-journal.json',
  );

  Future<Map<String, dynamic>?> read() async {
    final file = await _file;
    if (!await file.exists()) return null;
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> write(Map<String, dynamic> value) async {
    final file = await _file;
    if (await file.exists()) throw StateError('尚有未处理的恢复日志，请重启应用。');
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> clear() async {
    final file = await _file;
    if (await file.exists()) await file.delete();
  }
}
