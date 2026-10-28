import 'dart:async';
import 'dart:convert';

import '../platform/foundation.dart';
import 'package:riverpod/riverpod.dart';

import '../core/providers.dart';

enum WorkTaskStatus {
  running,
  waitingForApproval,
  completed,
  failed,
  cancelled,
  interrupted,
}

extension WorkTaskStatusLabel on WorkTaskStatus {
  String get label => switch (this) {
    WorkTaskStatus.running => '执行中',
    WorkTaskStatus.waitingForApproval => '等待批准',
    WorkTaskStatus.completed => '已完成',
    WorkTaskStatus.failed => '失败',
    WorkTaskStatus.cancelled => '已取消',
    WorkTaskStatus.interrupted => '已中断',
  };

  bool get isActive =>
      this == WorkTaskStatus.running ||
      this == WorkTaskStatus.waitingForApproval;
}

class WorkTaskLog {
  const WorkTaskLog(this.text, {this.isStderr = false});
  final String text;
  final bool isStderr;
}

class WorkTaskRecord {
  const WorkTaskRecord({
    required this.id,
    required this.conversationId,
    required this.title,
    required this.startedAt,
    required this.status,
    this.detail,
    this.finishedAt,
    this.exitCode,
    this.message,
    this.logs = const [],
    this.logsTruncated = false,
    this.stopRequested = false,
  });

  final String id;
  final String conversationId;
  final String title;
  final String? detail;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final WorkTaskStatus status;
  final int? exitCode;
  final String? message;
  final List<WorkTaskLog> logs;
  final bool logsTruncated;
  final bool stopRequested;

  WorkTaskRecord copyWith({
    String? detail,
    WorkTaskStatus? status,
    DateTime? finishedAt,
    int? exitCode,
    String? message,
    List<WorkTaskLog>? logs,
    bool? logsTruncated,
    bool? stopRequested,
  }) => WorkTaskRecord(
    id: id,
    conversationId: conversationId,
    title: title,
    detail: detail ?? this.detail,
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    message: message ?? this.message,
    logs: logs ?? this.logs,
    logsTruncated: logsTruncated ?? this.logsTruncated,
    stopRequested: stopRequested ?? this.stopRequested,
  );

  // Keep a small execution journal. Command output stays in memory only.
  Map<String, Object?> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'title': title,
    'detail': detail,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'exitCode': exitCode,
    'message': message,
  };

  factory WorkTaskRecord.fromJson(Map<String, dynamic> json) {
    final savedStatus = WorkTaskStatus.values.byName(json['status'] as String);
    return WorkTaskRecord(
      id: json['id'] as String,
      conversationId: json['conversationId'] as String,
      title: json['title'] as String,
      detail: json['detail'] as String?,
      startedAt: DateTime.parse(json['startedAt'] as String),
      finishedAt: savedStatus.isActive
          ? DateTime.now()
          : DateTime.tryParse(json['finishedAt'] as String? ?? ''),
      status: savedStatus.isActive ? WorkTaskStatus.interrupted : savedStatus,
      exitCode: json['exitCode'] as int?,
      message: savedStatus.isActive
          ? '应用已重启，执行状态未恢复；请检查进程或远端状态后再运行。'
          : json['message'] as String?,
    );
  }
}

final workTaskRuntimeProvider =
    NotifierProvider<WorkTaskRuntime, List<WorkTaskRecord>>(
      WorkTaskRuntime.new,
    );

/// Session-scoped execution records, not a background job scheduler.
class WorkTaskRuntime extends Notifier<List<WorkTaskRecord>> {
  static const storageKey = 'workTaskJournal.v1';
  static const _logLimit = 64000;
  final _stopHandlers = <String, FutureOr<void> Function()>{};
  final _pendingLogs = <String, WorkTaskRecord>{};
  Timer? _outputTimer;
  Future<void> _persistence = Future.value();
  var _sequence = 0;

  @override
  List<WorkTaskRecord> build() {
    ref.onDispose(() => _outputTimer?.cancel());
    final raw = ref.read(sharedPrefsProvider).getString(storageKey);
    if (raw == null) return const [];
    try {
      return List.unmodifiable(
        (jsonDecode(raw) as List).map(
          (item) =>
              WorkTaskRecord.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      );
    } catch (error) {
      debugPrint('Unable to restore work task journal: $error');
      return const [];
    }
  }

  String start({
    required String conversationId,
    required String title,
    String? detail,
    bool waitingForApproval = false,
    FutureOr<void> Function()? onStop,
  }) {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    if (onStop != null) _stopHandlers[id] = onStop;
    final retained = state.where((r) => r.status.isActive).toList();
    retained.addAll(state.where((r) => !r.status.isActive).take(99));
    retained.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    state = List.unmodifiable([
      WorkTaskRecord(
        id: id,
        conversationId: conversationId,
        title: title,
        detail: detail,
        startedAt: DateTime.now(),
        status: waitingForApproval
            ? WorkTaskStatus.waitingForApproval
            : WorkTaskStatus.running,
      ),
      ...retained,
    ]);
    _persist();
    return id;
  }

  void removeConversation(String conversationId) {
    for (final record in state.where(
      (r) => r.conversationId == conversationId,
    )) {
      _stopHandlers.remove(record.id);
      _pendingLogs.remove(record.id);
    }
    state = List.unmodifiable(
      state.where((r) => r.conversationId != conversationId),
    );
    _persist();
  }

  void waitingForApproval(String id, {String? detail}) {
    _update(
      id,
      (r) => r.status.isActive
          ? r.copyWith(
              status: WorkTaskStatus.waitingForApproval,
              detail: detail,
            )
          : r,
    );
    _persist();
  }

  void running(String id, {String? detail}) {
    _update(
      id,
      (r) => r.status.isActive
          ? r.copyWith(status: WorkTaskStatus.running, detail: detail)
          : r,
    );
    _persist();
  }

  void appendOutput(String id, String text, {bool isStderr = false}) {
    if (text.isEmpty || !ref.mounted) return;
    final record = _pendingLogs[id] ?? _find(id);
    if (record == null || !record.status.isActive) return;
    final logs = [...record.logs];
    var truncated = record.logsTruncated;
    if (text.length > _logLimit) {
      text = text.substring(text.length - _logLimit);
      logs.clear();
      truncated = true;
    }
    if (logs.isNotEmpty &&
        logs.last.isStderr == isStderr &&
        logs.last.text.length + text.length <= 4096) {
      final previous = logs.removeLast();
      logs.add(WorkTaskLog(previous.text + text, isStderr: isStderr));
    } else {
      logs.add(WorkTaskLog(text, isStderr: isStderr));
    }
    var length = logs.fold<int>(0, (sum, log) => sum + log.text.length);
    while (logs.length > 256) {
      length -= logs.removeAt(0).text.length;
      truncated = true;
    }
    while (length > _logLimit) {
      final first = logs.removeAt(0);
      final excess = length - _logLimit;
      if (first.text.length > excess) {
        logs.insert(
          0,
          WorkTaskLog(first.text.substring(excess), isStderr: first.isStderr),
        );
        length -= excess;
      } else {
        length -= first.text.length;
      }
      truncated = true;
    }
    _pendingLogs[id] = record.copyWith(
      logs: List.unmodifiable(logs),
      logsTruncated: truncated,
    );
    _outputTimer ??= Timer(const Duration(milliseconds: 80), _flushOutput);
  }

  void finish(
    String id, {
    WorkTaskStatus status = WorkTaskStatus.completed,
    int? exitCode,
    String? message,
  }) {
    _flushOutput();
    _update(
      id,
      (r) => r.status.isActive
          ? r.copyWith(
              status: status,
              finishedAt: DateTime.now(),
              exitCode: exitCode,
              message: message,
            )
          : r,
    );
    _stopHandlers.remove(id);
    _persist();
  }

  bool canStop(String id) => _stopHandlers.containsKey(id);

  Future<void> stop(String id) async {
    final record = _find(id);
    final handler = _stopHandlers[id];
    if (record == null ||
        !record.status.isActive ||
        record.stopRequested ||
        handler == null) {
      return;
    }
    _flushOutput();
    _update(id, (r) => r.copyWith(stopRequested: true));
    try {
      await handler();
      // The command owner marks completion after cancellation is observed.
    } catch (error) {
      _update(
        id,
        (r) => r.copyWith(stopRequested: false, message: '停止请求失败：$error'),
      );
    }
  }

  WorkTaskRecord? _find(String id) {
    for (final record in state) {
      if (record.id == id) return record;
    }
    return null;
  }

  void _update(String id, WorkTaskRecord Function(WorkTaskRecord) update) {
    if (!ref.mounted) return;
    _flushOutput();
    state = List.unmodifiable(state.map((r) => r.id == id ? update(r) : r));
  }

  void _flushOutput() {
    _outputTimer?.cancel();
    _outputTimer = null;
    if (!ref.mounted || _pendingLogs.isEmpty) return;
    state = List.unmodifiable(state.map((r) => _pendingLogs[r.id] ?? r));
    _pendingLogs.clear();
  }

  Future<void> flush() {
    _flushOutput();
    _persist();
    return _persistence;
  }

  void _persist() {
    if (!ref.mounted) return;
    final prefs = ref.read(sharedPrefsProvider);
    final encoded = jsonEncode(state.map((r) => r.toJson()).toList());
    _persistence = _persistence
        .then((_) async {
          if (!await prefs.setString(storageKey, encoded)) {
            throw StateError('任务记录保存失败');
          }
        })
        .catchError((Object error) {
          debugPrint('Unable to persist work task journal: $error');
        });
  }
}
