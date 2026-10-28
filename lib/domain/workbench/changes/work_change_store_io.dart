import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import '../../../platform/paths.dart';
import 'package:uuid/uuid.dart';

import 'work_file_change.dart';

Future<File> _file() async {
  final support = await getApplicationSupportDirectory();
  return File(p.join(support.path, 'workbench', 'changes.json'));
}

Future<List<WorkFileChange>> loadWorkChanges() async {
  final file = await _file();
  if (!await file.exists()) return const [];
  final json = jsonDecode(await file.readAsString()) as List;
  return [
    for (final value in json)
      WorkFileChange.fromJson(Map<String, dynamic>.from(value as Map)),
  ];
}

Future<void> saveWorkChanges(List<WorkFileChange> changes) async {
  final file = await _file();
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
  try {
    await temporary.writeAsString(
      jsonEncode(changes.map((change) => change.toJson()).toList()),
      flush: true,
    );
    await temporary.rename(file.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
