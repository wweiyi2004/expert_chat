import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  });
  final String runId, note;
  final int used, limit, step, reviewAhead, reviewedLimit, revision;
  final bool autoExtend, reviewing, finishing, active;
  WorkRoundProgress copyWith({
    int? used,
    int? limit,
    int? reviewedLimit,
    int? revision,
    bool? reviewing,
    bool? finishing,
    bool? active,
    String? note,
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
  );
}

final workRoundsProvider =
    NotifierProvider<WorkRounds, Map<String, WorkRoundProgress>>(
      WorkRounds.new,
    );

class WorkRounds extends Notifier<Map<String, WorkRoundProgress>> {
  @override
  Map<String, WorkRoundProgress> build() => {};
  void start(String conversation, String runId, SessionPolicy policy) {
    state = {
      ...state,
      conversation: WorkRoundProgress(
        runId: runId,
        limit: policy.toolRounds,
        step: policy.roundExtension,
        reviewAhead: policy.roundReviewAhead,
        autoExtend: policy.autoExtendRounds,
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
