import 'dart:async';

import '../../data/task_budget_prefs.dart';

/// A single instance survives model retries and every tool round in a turn.
class TaskBudget {
  TaskBudget(
    this.prefs, {
    required this.onExhausted,
    Map<String, dynamic> snapshot = const {},
  }) {
    searches = (snapshot['searches'] as num?)?.toInt() ?? 0;
    toolCalls = (snapshot['toolCalls'] as num?)?.toInt() ?? 0;
    _priorElapsed = Duration(
      milliseconds: (snapshot['elapsedMs'] as num?)?.toInt() ?? 0,
    );
    resumeWork();
  }

  final TaskBudgetPrefs prefs;
  final void Function(String reason) onExhausted;
  Duration _priorElapsed = Duration.zero;
  Map<String, dynamic> toJson() => {
    'workSeconds': prefs.workSeconds,
    'timeLimitEnabled': prefs.workSeconds > 0,
    'maxSearches': prefs.maxSearches,
    'maxToolCalls': prefs.maxToolCalls,
    'elapsedMs': (_priorElapsed + _clock.elapsed).inMilliseconds,
    'searches': searches,
    'toolCalls': toolCalls,
  };
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  Timer? _checkpointTimer;
  void Function()? onChanged;
  bool _disposed = false;
  String? reason;
  int searches = 0;
  int toolCalls = 0;
  bool get finishing => reason != null;
  int _children = 0;
  bool _rootWorking = false;
  bool get isWorking =>
      !_disposed && !finishing && (_rootWorking || _children > 0);

  void childExecution(bool active) {
    _children = (_children + (active ? 1 : -1)).clamp(0, 100000);
    _syncClock();
  }

  void resumeWork() {
    _rootWorking = true;
    _syncClock();
  }

  void _syncClock() {
    _timer?.cancel();
    if (!isWorking) {
      _clock.stop();
      _checkpointTimer?.cancel();
      _checkpointTimer = null;
      onChanged?.call();
      return;
    }
    _clock.start();
    _checkpointTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => onChanged?.call(),
    );
    if (prefs.workSeconds == 0) return;
    final remaining =
        Duration(seconds: prefs.workSeconds) - _priorElapsed - _clock.elapsed;
    if (remaining <= Duration.zero) {
      requestFinish('任务执行时间已达上限');
      return;
    }
    _timer = Timer(remaining, () => requestFinish('任务执行时间已达上限'));
  }

  /// An answer/approval wait pauses only the main actor; active children still
  /// consume the same wall clock once, never once per actor.
  void answerStarted() {
    _rootWorking = false;
    _syncClock();
  }

  void waitForApproval() => answerStarted();

  bool takeTool({bool resumeRoot = true}) {
    if (finishing || _disposed) return false;
    if (toolCalls >= prefs.maxToolCalls) {
      requestFinish('工具调用次数已达上限');
      return false;
    }
    toolCalls++;
    onChanged?.call();
    if (resumeRoot) resumeWork();
    return !finishing;
  }

  bool takeSearch({bool resumeRoot = true}) {
    if (finishing || _disposed) return false;
    if (searches >= prefs.maxSearches) {
      requestFinish('搜索次数已达上限');
      return false;
    }
    searches++;
    onChanged?.call();
    if (resumeRoot) resumeWork();
    return !finishing;
  }

  void requestFinish(String message) {
    if (_disposed || finishing) return;
    reason = message;
    answerStarted();
    onExhausted(message);
  }

  void dispose() {
    _disposed = true;
    answerStarted();
  }
}
