import 'dart:async';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'session_policy.dart';

class WorkRoundProgress {
  const WorkRoundProgress({
    required this.runId,
    required this.limit,
    required this.step,
    required this.reviewAhead,
    required this.autoExtend,
    this.used = 0,
    this.reviewedLimit = 0,
    this.reviewing = false,
    this.finishing = false,
    this.active = true,
    this.revision = 0,
    this.note = '',
    this.pauseRequested = false,
    this.paused = false,
  });
  final String runId, note;
  final int used, limit, step, reviewAhead, reviewedLimit, revision;
  final bool autoExtend, reviewing, finishing, active, pauseRequested, paused;
  WorkRoundProgress copyWith({
    int? used,
    int? limit,
    int? reviewedLimit,
    int? revision,
    bool? reviewing,
    bool? finishing,
    bool? active,
    String? note,
    bool? pauseRequested,
    bool? paused,
  }) => WorkRoundProgress(
    runId: runId,
    limit: limit ?? this.limit,
    step: step,
    reviewAhead: reviewAhead,
    autoExtend: autoExtend,
    used: used ?? this.used,
    reviewedLimit: reviewedLimit ?? this.reviewedLimit,
    revision: revision ?? this.revision,
    reviewing: reviewing ?? this.reviewing,
    finishing: finishing ?? this.finishing,
    active: active ?? this.active,
    note: note ?? this.note,
    pauseRequested: pauseRequested ?? this.pauseRequested,
    paused: paused ?? this.paused,
  );
}

final workRoundsProvider =
    NotifierProvider<WorkRounds, Map<String, WorkRoundProgress>>(
      WorkRounds.new,
    );

class WorkRounds extends Notifier<Map<String, WorkRoundProgress>> {
  final _gates = <String, Completer<void>>{};
  void requestPause(String conversation) {
    final current = state[conversation];
    if (current == null || !current.active) return;
    state = {
      ...state,
      conversation: current.copyWith(
        pauseRequested: true,
        note: '暂停已请求：当前完整工具轮结束后生效；已提交后台进程继续。',
      ),
    };
  }

  void resume(String conversation) {
    final current = state[conversation];
    if (current != null) {
      state = {
        ...state,
        conversation: current.copyWith(
          pauseRequested: false,
          paused: false,
          note: '已继续：下一模型/工具轮将读取最新约束和设置。',
        ),
      };
    }
    final gate = _gates.remove(conversation);
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<void> waitAtBoundary(
    String conversation,
    CancelToken token, {
    bool markPaused = true,
  }) async {
    final current = state[conversation];
    if (current == null || !current.pauseRequested) return;
    state = {
      ...state,
      conversation: current.copyWith(
        paused: markPaused || current.paused,
        note: markPaused ? '已在轮次边界暂停；已提交后台进程继续。' : current.note,
      ),
    };
    final gate = _gates.putIfAbsent(conversation, () => Completer<void>());
    await Future.any<void>([
      gate.future,
      token.whenCancel.then<void>((_) => throw token.cancelError!),
    ]);
    if (token.isCancelled) throw token.cancelError!;
  }

  @override
  Map<String, WorkRoundProgress> build() => {};
  void start(
    String conversation,
    String runId,
    SessionPolicy policy, {
    bool preservePause = false,
    int? restoredUsed,
    int? restoredLimit,
    int? extraRounds,
  }) {
    final previous = state[conversation];
    if (!preservePause) resume(conversation);
    state = {
      ...state,
      conversation: WorkRoundProgress(
        runId: runId,
        limit: extraRounds != null
            ? (restoredLimit ?? previous?.limit ?? restoredUsed ?? 0) +
                  extraRounds
            : restoredLimit ??
                  (preservePause ? previous?.limit : null) ??
                  policy.toolRounds,
        used: restoredUsed ?? (preservePause ? previous?.used : null) ?? 0,
        step: policy.roundExtension,
        reviewAhead: policy.roundReviewAhead,
        autoExtend: policy.autoExtendRounds,
        pauseRequested: preservePause && (previous?.pauseRequested ?? false),
        paused: preservePause && (previous?.paused ?? false),
      ),
    };
  }

  void update(
    String conversation,
    String runId,
    WorkRoundProgress Function(WorkRoundProgress) transform,
  ) {
    final current = state[conversation];
    if (current == null || current.runId != runId) return;
    state = {...state, conversation: transform(current)};
  }

  void addRounds(String conversation) {
    final current = state[conversation];
    if (current == null || !current.active || current.finishing) return;
    state = {
      ...state,
      conversation: current.copyWith(
        limit: current.limit + current.step,
        revision: current.revision + 1,
        note: '手动增加 ${current.step} 轮',
        reviewing: false,
      ),
    };
  }
}
