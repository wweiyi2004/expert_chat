import 'dart:async';

import 'package:dio/dio.dart';

import '../../data/task_budget_prefs.dart';
import '../support/diagnostic_trace.dart';
import 'generation_stream.dart';
import 'task_budget.dart';

/// Owns one accepted turn from preflight until its async work has unwound.
/// No widget or Riverpod state is needed to cancel, wait, or enforce its budget.
class GenerationExecution {
  bool _active = false;
  bool _cancelled = false;
  bool _disposed = false;
  int _toolDepth = 0;
  Completer<void>? _idle;
  CancelToken? _request;
  GenerationStream? _stream;
  TaskBudget? _budget;
  DiagnosticTicket? _diagnostic;

  bool get isActive => _active;
  bool get isCancelled => _cancelled;
  bool get isExecutingTool => _toolDepth > 0;
  TaskBudget? get budget => _budget;
  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();

  bool tryStart() {
    if (_active || _disposed) return false;
    _active = true;
    _cancelled = false;
    _idle = Completer<void>();
    _diagnostic = DiagnosticTrace.instance.start(
      DiagnosticOperation.generation,
    );
    return true;
  }

  void attachRequest(CancelToken token) {
    if (_disposed || _cancelled) {
      token.cancel('generation stopped');
      return;
    }
    _request = token;
  }

  void releaseRequest(CancelToken token) {
    if (identical(_request, token)) _request = null;
  }

  Future<GenerationStreamResult> consumeStream<T>(
    Stream<T> source, {
    required CancelToken cancelToken,
    required void Function(T) onData,
  }) async {
    if (_stream != null) throw StateError('A model stream is already active.');
    final stream = GenerationStream();
    _stream = stream;
    if (_disposed || _cancelled || cancelToken.isCancelled) stream.cancel();
    unawaited(cancelToken.whenCancel.then((_) => stream.cancel()));
    try {
      return await stream.consume(
        source,
        onData: (value) {
          if (!cancelToken.isCancelled && !_cancelled && !_disposed) {
            onData(value);
          }
        },
      );
    } finally {
      if (identical(_stream, stream)) _stream = null;
    }
  }

  void beginBudget(
    TaskBudgetPrefs prefs, {
    required void Function() beforeCancel,
    Map<String, dynamic> snapshot = const {},
  }) {
    if (_disposed || _cancelled) return;
    if (_budget != null) {
      _budget!.resumeWork();
      return;
    }
    _budget = TaskBudget(
      prefs,
      snapshot: snapshot,
      onExhausted: (reason) {
        if (_disposed || _cancelled) return;
        DiagnosticTrace.instance.record(
          _diagnostic,
          DiagnosticPhase.budgetExhausted,
        );
        try {
          beforeCancel();
        } finally {
          // Budget exhaustion permits a separate final-answer request. It
          // must not be mistaken for an explicit user cancellation.
          cancelRequest('task budget: $reason');
        }
      },
    );
  }

  void endBudget() {
    _budget?.dispose();
    _budget = null;
  }

  /// Stops the current request while retaining the turn and its used budget.
  void cancelRequest([String? reason]) {
    _request?.cancel(reason);
    _stream?.cancel();
  }

  void cancel() {
    _cancelled = true;
    endBudget();
    cancelRequest('user stopped generation');
  }

  Future<T> runTools<T>(Future<T> Function() action) async {
    _toolDepth++;
    final trace = DiagnosticTrace.instance;
    final ticket = trace.start(DiagnosticOperation.toolBatch);
    try {
      final result = await action();
      trace.record(ticket, DiagnosticPhase.finished);
      return result;
    } catch (_) {
      trace.record(ticket, DiagnosticPhase.failed);
      rethrow;
    } finally {
      _toolDepth--;
    }
  }

  void finish() {
    DiagnosticTrace.instance.record(
      _diagnostic,
      _cancelled ? DiagnosticPhase.cancelled : DiagnosticPhase.finished,
    );
    _diagnostic = null;
    _budget?.waitForApproval();
    _active = false;
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  void dispose() {
    _disposed = true;
    cancel();
    finish();
  }
}
