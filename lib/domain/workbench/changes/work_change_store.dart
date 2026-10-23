import 'work_change_store_stub.dart'
    if (dart.library.io) 'work_change_store_io.dart'
    as platform;
import 'work_file_change.dart';

Future<List<WorkFileChange>> loadWorkChanges() => platform.loadWorkChanges();
Future<void> saveWorkChanges(List<WorkFileChange> changes) =>
    platform.saveWorkChanges(changes);
