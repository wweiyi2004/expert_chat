import 'dart:convert';
import 'dart:async';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/workbench/processes/work_hook_runtime.dart';
import '../domain/workbench/processes/work_process_runtime.dart';
export '../domain/workbench/processes/work_hook_runtime.dart';
export '../domain/workbench/processes/work_process_runtime.dart';

final workProcessesProvider = Provider<WorkProcessRuntime>((ref) {
  final runtime = WorkProcessRuntime();
  final prefs = ref.read(sharedPrefsProvider);
  try {
    runtime.restoreJournal(
      (jsonDecode(prefs.getString('workProcessJournal.v1') ?? '[]') as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList(),
    );
  } catch (_) {}
  Timer? saveTimer;
  void save() {
    saveTimer ??= Timer(const Duration(milliseconds: 400), () {
      saveTimer = null;
      unawaited(
        prefs.setString('workProcessJournal.v1', jsonEncode(runtime.journal())),
      );
    });
  }

  runtime.addListener(save);
  ref.onDispose(() {
    saveTimer?.cancel();
    runtime.removeListener(save);
    runtime.dispose();
  });
  return runtime;
});

final workHooksProvider = Provider<WorkHookRuntime>((ref) {
  final prefs = ref.read(sharedPrefsProvider);
  List<WorkHookDefinition> definitions;
  try {
    definitions = (jsonDecode(prefs.getString('workHooks.v1') ?? '[]') as List)
        .map(
          (j) =>
              WorkHookDefinition.fromJson(Map<String, dynamic>.from(j as Map)),
        )
        .toList();
  } catch (_) {
    definitions = [];
  }
  final runtime = WorkHookRuntime(
    processes: ref.read(workProcessesProvider),
    definitions: definitions,
    persist: (definitions) async {
      if (!await prefs.setString(
        'workHooks.v1',
        jsonEncode(definitions.map((d) => d.toJson()).toList()),
      )) {
        throw StateError('Hook 配置保存失败');
      }
    },
  );
  ref.onDispose(runtime.dispose);
  return runtime;
});
