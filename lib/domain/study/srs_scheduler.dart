import '../../data/study_models.dart';

/// SM-2 style ratings for review cards.
enum SrsRating { again, hard, good, easy }

/// Pure SRS scheduler (testable, no I/O).
class SrsScheduler {
  const SrsScheduler();

  static const double minEase = 1.3;
  static const double defaultEase = 2.5;

  /// Apply [rating] to [card] as of [now] (defaults to current time).
  StudyCard apply(StudyCard card, SrsRating rating, {DateTime? now}) {
    final at = now ?? DateTime.now();
    var ease = card.ease;
    var reps = card.repetitions;
    var interval = card.intervalDays;

    switch (rating) {
      case SrsRating.again:
        reps = 0;
        interval = 0;
        ease = (ease - 0.2).clamp(minEase, 5.0);
        return card.copyWith(
          ease: ease,
          intervalDays: interval,
          repetitions: reps,
          dueAt: at.add(const Duration(minutes: 10)),
          lastReviewedAt: at,
        );
      case SrsRating.hard:
        ease = (ease - 0.15).clamp(minEase, 5.0);
        if (reps <= 0) {
          interval = 1;
          reps = 1;
        } else {
          interval = (interval * 1.2).ceil().clamp(1, 3650);
          reps += 1;
        }
        break;
      case SrsRating.good:
        if (reps <= 0) {
          interval = 1;
          reps = 1;
        } else if (reps == 1) {
          interval = 3;
          reps = 2;
        } else {
          interval = (interval * ease).round().clamp(1, 3650);
          reps += 1;
        }
        break;
      case SrsRating.easy:
        ease = (ease + 0.15).clamp(minEase, 5.0);
        if (reps <= 0) {
          interval = 2;
          reps = 1;
        } else if (reps == 1) {
          interval = 4;
          reps = 2;
        } else {
          interval = (interval * ease * 1.3).round().clamp(1, 3650);
          reps += 1;
        }
        break;
    }

    return card.copyWith(
      ease: ease,
      intervalDays: interval,
      repetitions: reps,
      dueAt: DateTime(at.year, at.month, at.day).add(Duration(days: interval)),
      lastReviewedAt: at,
    );
  }

  /// Cards due on or before end of [day] (local), not suspended.
  List<StudyCard> dueQueue(List<StudyCard> cards, {DateTime? day}) {
    final d = day ?? DateTime.now();
    final end = DateTime(d.year, d.month, d.day, 23, 59, 59, 999);
    final due = cards
        .where((c) => !c.suspended && !c.dueAt.isAfter(end))
        .toList();
    due.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return due;
  }

  /// Cards whose exact due time has arrived. Unlike [dueQueue], this is used
  /// by an active review session so an `Again` card scheduled ten minutes from
  /// now is not shown again immediately.
  List<StudyCard> readyQueue(List<StudyCard> cards, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final ready = cards
        .where((c) => !c.suspended && !c.dueAt.isAfter(at))
        .toList();
    ready.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return ready;
  }
}
