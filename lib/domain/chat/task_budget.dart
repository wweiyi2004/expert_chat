import 'dart:async';

import '../../data/task_budget_prefs.dart';

/// A single instance survives model retries and every tool round in a turn.
class TaskBudget {
  TaskBudget(this.prefs, {required this.onExhausted}) {
    resumeWork();
  }

  final TaskBudgetPrefs prefs;
  final void Function(String reason) onExhausted;
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _disposed = false;
  String? reason;
  int searches = 0;
  int toolCalls = 0;
  bool get finishing => reason != null;

  void resumeWork() {
    if (_disposed || finishing) return;
    _timer?.cancel();
    final remaining = Duration(seconds: prefs.workSeconds) - _clock.elapsed;
    if (remaining <= Duration.zero) {
      requestFinish('任务执行时间已达上限');
      return;
    }
    _clock.start();
    _timer = Timer(remaining, () => requestFinish('任务执行时间已达上限'));
  }

  /// Do not cut a normal answer in half. A later tool call resumes the same
  /// accumulated budget; no new budget is allocated for a model retry.
  void answerStarted() {
    _clock.stop();
    _timer?.cancel();
  }

  void waitForApproval() {
    _clock.stop();
    _timer?.cancel();
  }

  bool takeTool() {
    if (finishing || _disposed) return false;
    if (toolCalls >= prefs.maxToolCalls) {
      requestFinish('工具调用次数已达上限');
      return false;
    }
    toolCalls++;
    resumeWork();
    return !finishing;
  }

  bool takeSearch() {
    if (finishing || _disposed) return false;
    if (searches >= prefs.maxSearches) {
      requestFinish('搜索次数已达上限');
      return false;
    }
    searches++;
    resumeWork();
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
