import '../../data/models.dart';

/// One row in the DeepSeek-style thinking chain: prose or a tool step.
class ThinkingTimelineSegment {
  const ThinkingTimelineSegment.reasoning(this.text) : activity = null;

  const ThinkingTimelineSegment.activity(this.activity) : text = null;

  final String? text;
  final SearchActivity? activity;

  bool get isReasoning => text != null;
}

/// Split [reasoning] around tool steps using each activity's
/// [SearchActivity.reasoningOffset]. Legacy activities with offset 0 and no
/// reasoning stay after the prose so old transcripts still read naturally.
List<ThinkingTimelineSegment> buildThinkingTimeline({
  required String reasoning,
  required List<SearchActivity> activities,
}) {
  final text = reasoning.trim();
  if (activities.isEmpty) {
    return text.isEmpty ? const [] : [ThinkingTimelineSegment.reasoning(text)];
  }
  final ordered = [...activities]
    ..sort((a, b) {
      final byOffset = a.reasoningOffset.compareTo(b.reasoningOffset);
      if (byOffset != 0) return byOffset;
      return 0;
    });
  final allLegacy = ordered.every((a) => a.reasoningOffset <= 0);
  if (allLegacy) {
    return [
      if (text.isNotEmpty) ThinkingTimelineSegment.reasoning(text),
      for (final activity in ordered)
        ThinkingTimelineSegment.activity(activity),
    ];
  }
  final out = <ThinkingTimelineSegment>[];
  var cursor = 0;
  for (final activity in ordered) {
    final cut = activity.reasoningOffset.clamp(0, reasoning.length);
    if (cut > cursor) {
      final slice = reasoning.substring(cursor, cut).trim();
      if (slice.isNotEmpty) {
        out.add(ThinkingTimelineSegment.reasoning(slice));
      }
      cursor = cut;
    }
    out.add(ThinkingTimelineSegment.activity(activity));
  }
  if (cursor < reasoning.length) {
    final slice = reasoning.substring(cursor).trim();
    if (slice.isNotEmpty) {
      out.add(ThinkingTimelineSegment.reasoning(slice));
    }
  }
  return out;
}
