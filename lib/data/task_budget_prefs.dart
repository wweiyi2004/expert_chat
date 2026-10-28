import 'dart:convert';

enum TaskBudgetPreset { quick, standard, deep, custom }

/// One budget for planning and tools, not a limit on normal answer length.
/// Default tasks have no local time/search/tool limit. Explicit limits persist.
class TaskBudgetPrefs {
  const TaskBudgetPrefs({
    this.preset = TaskBudgetPreset.custom,
    this.workSeconds = 0,
    this.maxSearches = unlimited,
    this.maxToolCalls = unlimited,
    this.workResponseTimeoutSeconds = 120,
  });

  /// Count sentinel that is never reached; kept a non-negative int so saved
  /// budgets and backups keep their integer format.
  static const unlimited = 1 << 30;

  /// Highest explicit count; the former default, read back as [unlimited].
  static const maxCount = 192;

  static bool isUnlimited(int count) => count >= maxCount;

  /// Normalises a saved count, mapping legacy 192 to [unlimited].
  static int count(int value) =>
      isUnlimited(value) ? unlimited : value.clamp(0, maxCount - 1);

  static String describeCount(int count) =>
      isUnlimited(count) ? '不限' : '$count';

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
    'timeLimitEnabled': workSeconds > 0,
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

    final legacyDefault =
        raw['timeLimitEnabled'] == null &&
        (raw['preset'] == null || raw['preset'] == 'custom') &&
        raw['workSeconds'] == 900 &&
        isUnlimited(number('maxSearches', unlimited, 0, unlimited)) &&
        isUnlimited(number('maxToolCalls', unlimited, 0, unlimited));
    final seconds = number('workSeconds', 0, 0, 3600);
    return TaskBudgetPrefs(
      preset: TaskBudgetPreset.values.firstWhere(
        (p) => p.name == raw['preset'],
        orElse: () => TaskBudgetPreset.custom,
      ),
      workSeconds:
          legacyDefault ||
              raw['timeLimitEnabled'] == false ||
              raw['workSeconds'] == 0 ||
              !raw.containsKey('workSeconds')
          ? 0
          : seconds.clamp(30, 3600),
      maxSearches: count(number('maxSearches', unlimited, 0, unlimited)),
      maxToolCalls: count(number('maxToolCalls', unlimited, 0, unlimited)),
      workResponseTimeoutSeconds: number(
        'workResponseTimeoutSeconds',
        120,
        30,
        600,
      ),
    );
  }
}
