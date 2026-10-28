import 'dart:convert';
import 'dart:async';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../domain/workbench/agents/work_agent_runtime.dart';
export '../domain/workbench/agents/work_agent_runtime.dart';

/// Null preserves the existing default (the session model); an explicit empty
/// pool disables spawning until the user chooses a model.
final workAgentModelPoolProvider =
    NotifierProvider<WorkAgentModelPool, List<WorkAgentModelOption>?>(
      WorkAgentModelPool.new,
    );

class WorkAgentModelPool extends Notifier<List<WorkAgentModelOption>?> {
  static const storageKey = 'workAgentModelPool.v1';
  @override
  List<WorkAgentModelOption>? build() {
    final raw = ref.read(sharedPrefsProvider).getString(storageKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List)
          .map(
            (item) => WorkAgentModelOption.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<WorkAgentModelOption> models) async {
    if (!await ref
        .read(sharedPrefsProvider)
        .setString(
          storageKey,
          jsonEncode(models.map((m) => m.toJson()).toList()),
        )) {
      throw StateError('子代理模型池保存失败');
    }
    state = List.unmodifiable(models);
  }
}

final workAgentsProvider = Provider<WorkAgentRuntime>((ref) {
  final prefs = ref.read(sharedPrefsProvider);
  final runtime = WorkAgentRuntime(
    persistJournal: (rows) async {
      if (!await prefs.setString('workAgentJournal.v1', jsonEncode(rows))) {
        throw StateError('子代理恢复快照保存失败；未继续派发操作');
      }
    },
  );
  try {
    runtime.restoreJournal(
      (jsonDecode(prefs.getString('workAgentJournal.v1') ?? '[]') as List)
          .map((j) => Map<String, dynamic>.from(j as Map))
          .toList(),
    );
  } catch (_) {}
  Timer? saveTimer;
  void save() {
    saveTimer ??= Timer(const Duration(milliseconds: 400), () {
      saveTimer = null;
      unawaited(
        runtime.flushJournal().catchError((Object _) {
          // Critical dispatch awaits flushJournal and surfaces the failure.
        }),
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

final workAgentLimitsProvider =
    NotifierProvider<WorkAgentLimitSettings, WorkAgentLimits>(
      WorkAgentLimitSettings.new,
    );

class WorkAgentLimitSettings extends Notifier<WorkAgentLimits> {
  @override
  WorkAgentLimits build() {
    try {
      final raw = ref.read(sharedPrefsProvider).getString('workAgentLimits.v1');
      return raw == null
          ? const WorkAgentLimits()
          : WorkAgentLimits.fromJson(
              Map<String, dynamic>.from(jsonDecode(raw) as Map),
            );
    } catch (_) {
      return const WorkAgentLimits();
    }
  }

  Future<void> save(WorkAgentLimits limits) async {
    final safe = WorkAgentLimits.fromJson(limits.toJson());
    if (!await ref
        .read(sharedPrefsProvider)
        .setString('workAgentLimits.v1', jsonEncode(safe.toJson()))) {
      throw StateError('代理限制保存失败');
    }
    state = safe;
  }
}
