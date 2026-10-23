import 'work_file_change.dart';

Future<List<WorkFileChange>> loadWorkChanges() async => const [];
Future<void> saveWorkChanges(List<WorkFileChange> changes) async =>
    throw UnsupportedError('当前平台不支持保存工作文件快照。');
