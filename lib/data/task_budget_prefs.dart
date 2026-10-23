import 'dart:convert';

enum TaskBudgetPreset { quick, standard, deep, custom }

/// One budget for planning and tools, not a limit on normal answer length.
class TaskBudgetPrefs {
  const TaskBudgetPrefs({
    this.preset = TaskBudgetPreset.custom,
    this.workSeconds = 900,
    this.maxSearches = 192,
    this.maxToolCalls = 192,
    this.workResponseTimeoutSeconds = 120,
  });

  final TaskBudgetPreset preset;
  final int workSeconds;
  final int maxSearches;
  final int maxToolCalls;

  /// Client-side first-response/header wait, independent of stream idle time.
  final int workResponseTimeoutSeconds;

  TaskBudgetPrefs copyWith({int? workResponseTimeoutSeconds}) =>
      TaskBudgetPrefs(
        preset: preset,
        workSeconds: workSeconds,
        maxSearches: maxSearches,
        maxToolCalls: maxToolCalls,
        workResponseTimeoutSeconds:
            workResponseTimeoutSeconds ?? this.workResponseTimeoutSeconds,
      );

  static TaskBudgetPrefs forPreset(TaskBudgetPreset preset) => switch (preset) {
    TaskBudgetPreset.quick => const TaskBudgetPrefs(
      preset: TaskBudgetPreset.quick,
      workSeconds: 120,
      maxSearches: 1,
      maxToolCalls: 4,
    ),
    TaskBudgetPreset.standard => const TaskBudgetPrefs(
      preset: TaskBudgetPreset.standard,
      workSeconds: 300,
      maxSearches: 3,
      maxToolCalls: 12,
    ),
    TaskBudgetPreset.deep => const TaskBudgetPrefs(
      preset: TaskBudgetPreset.deep,
      workSeconds: 900,
      maxSearches: 8,
      maxToolCalls: 32,
    ),
    TaskBudgetPreset.custom => const TaskBudgetPrefs(),
  };

  String get label => switch (preset) {
    TaskBudgetPreset.quick => '快速',
    TaskBudgetPreset.standard => '标准',
    TaskBudgetPreset.deep => '深入',
    TaskBudgetPreset.custom => '自定义',
  };

  Map<String, dynamic> toJson() => {
    'preset': preset.name,
    'workSeconds': workSeconds,
    'maxSearches': maxSearches,
    'maxToolCalls': maxToolCalls,
    'workResponseTimeoutSeconds': workResponseTimeoutSeconds,
  };

  static TaskBudgetPrefs decode(String? raw) {
    try {
      return fromJson(jsonDecode(raw ?? '{}'));
    } catch (_) {
      return const TaskBudgetPrefs();
    }
  }

  static TaskBudgetPrefs fromJson(Object? raw) {
    if (raw is! Map) return const TaskBudgetPrefs();
    int number(String key, int fallback, int min, int max) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toInt().clamp(min, max)
          : fallback;
    }

    return TaskBudgetPrefs(
      preset: TaskBudgetPreset.values.firstWhere(
        (p) => p.name == raw['preset'],
        orElse: () => TaskBudgetPreset.custom,
      ),
      workSeconds: number('workSeconds', 900, 30, 3600),
      maxSearches: number('maxSearches', 192, 0, 192),
      maxToolCalls: number('maxToolCalls', 192, 0, 192),
      workResponseTimeoutSeconds: number(
        'workResponseTimeoutSeconds',
        120,
        30,
        600,
      ),
    );
  }
}
