import 'package:characters/characters.dart';

import '../../data/models.dart';

/// Computes written length and per-turn quotas for director / story sessions.
///
/// [Conversation.targetTotalChars] is the novel target (Unicode graphemes).
/// When it is `0`, no budget is applied.
class StoryLengthBudget {
  const StoryLengthBudget._({
    required this.targetTotal,
    required this.written,
    required this.remaining,
    required this.beatCount,
    required this.plotCursor,
    required this.beatsLeft,
    required this.perBeatSuggest,
    required this.turnMin,
    required this.turnMax,
    required this.progressRatio,
  });

  final int targetTotal;
  final int written;
  final int remaining;
  final int beatCount;
  final int plotCursor;
  final int beatsLeft;

  /// Suggested characters still to write for the current beat (rough).
  final int perBeatSuggest;

  /// Soft band for **this turn's** output length.
  final int turnMin;
  final int turnMax;

  /// 0..1 completion vs target (clamped).
  final double progressRatio;

  bool get hasTarget => targetTotal > 0;

  bool get targetReached => hasTarget && written >= targetTotal;

  /// Count story body on the active path: assistant text only (director cues
  /// and user lines are excluded; generated-image bubbles ignored).
  static int countWrittenChars(Conversation conversation) {
    var total = 0;
    for (final m in conversation.activePath) {
      if (m.role != MessageRole.assistant) continue;
      if (m.kind == MessageKind.generatedImage) continue;
      total += m.content.characters.length;
    }
    return total;
  }

  /// `null` when the conversation has no target length.
  static StoryLengthBudget? forConversation(Conversation conversation) {
    final target = conversation.targetTotalChars;
    if (target <= 0) return null;

    final written = countWrittenChars(conversation);
    final remaining = (target - written).clamp(0, target);
    final beats = conversation.outlineBeats;
    final beatCount = beats.length;
    final cursor = conversation.plotCursor.clamp(0, beatCount == 0 ? 0 : beatCount);
    // Include the current unfinished beat in the remaining denominator.
    final beatsLeft = beatCount == 0
        ? 1
        : (beatCount - cursor).clamp(1, beatCount);

    final perBeat = remaining <= 0 ? 0 : (remaining / beatsLeft).round();

    // One "继续下一节" is a fraction of a beat — aim ~1/3 of remaining beat
    // budget, clamped so models get a usable band without dumping a whole act.
    final int turnMin;
    final int turnMax;
    if (remaining <= 0) {
      turnMin = 0;
      turnMax = 0;
    } else if (remaining < 900) {
      turnMin = (remaining * 0.6).round().clamp(200, remaining);
      turnMax = remaining;
    } else {
      final center = (perBeat * 0.34).round().clamp(700, 2800);
      final cappedCenter = center > remaining ? remaining : center;
      var minV = (cappedCenter * 0.7).round().clamp(500, remaining);
      var maxV = (cappedCenter * 1.25).round();
      if (maxV > remaining) maxV = remaining;
      if (maxV > 3500) maxV = remaining < 3500 ? remaining : 3500;
      if (minV > maxV) minV = (maxV * 0.75).round().clamp(1, maxV);
      turnMin = minV;
      turnMax = maxV;
    }

    final ratio = target == 0 ? 0.0 : (written / target).clamp(0.0, 1.0);

    return StoryLengthBudget._(
      targetTotal: target,
      written: written,
      remaining: remaining,
      beatCount: beatCount,
      plotCursor: cursor,
      beatsLeft: beatsLeft,
      perBeatSuggest: perBeat,
      turnMin: turnMin,
      turnMax: turnMax,
      progressRatio: ratio,
    );
  }

  /// Compact UI line, e.g. `已写 1.2万/8万 · 本拍约6千 · 本回合1.5–2.5千`.
  String sessionLabel() {
    final w = formatChars(written);
    final t = formatChars(targetTotal);
    if (targetReached) {
      return '已写 $w/$t（已达目标）';
    }
    final parts = <String>['已写 $w/$t'];
    if (beatCount > 0) {
      parts.add('本拍约${formatChars(perBeatSuggest)}');
    }
    if (turnMax > 0) {
      parts.add('本回合${formatChars(turnMin)}–${formatChars(turnMax)}');
    }
    return parts.join(' · ');
  }

  /// Hard-constraint block injected into the story system prompt.
  String promptBlock({required bool advancePlot}) {
    final b = StringBuffer()
      ..writeln('【篇幅约束·不可违背】')
      ..writeln(
        '全书目标约 ${formatChars(targetTotal)}字；'
        '目前已写约 ${formatChars(written)}字'
        '（完成 ${(progressRatio * 100).toStringAsFixed(0)}%），'
        '剩余约 ${formatChars(remaining)}字。',
      );

    if (beatCount > 0) {
      final beatNo = plotCursor < beatCount ? plotCursor + 1 : beatCount;
      b.writeln(
        '大纲共 $beatCount 拍，当前第 $beatNo 拍；'
        '剩余约 $beatsLeft 拍（含当前），本拍建议仍写约 ${formatChars(perBeatSuggest)}字。',
      );
    }

    if (targetReached) {
      b.writeln(
        '已达或超过目标总字数：本回合应自然收束或精炼收尾，'
        '禁止为凑字数灌水、重复已写情节或无意义扩写。',
      );
    } else if (turnMax > 0) {
      b.writeln(
        advancePlot
            ? '本回合（推进情节）输出控制在约 ${formatChars(turnMin)}–${formatChars(turnMax)}字：'
                  '完成当前节拍应有的推进，不要提前写后续未解锁节拍；'
                  '不要远低于下限（过短）也不要远超上限（灌水）。'
            : '本回合输出控制在约 ${formatChars(turnMin)}–${formatChars(turnMax)}字：'
                  '执行导演指令并推进必要情节，禁止注水与无目的的风景/回忆堆砌。',
      );
    }

    b.write('篇幅服从硬性禁忌与当前大纲节拍；冲突时以禁忌与节拍为准，篇幅次之。');
    return b.toString();
  }

  /// Human-friendly Chinese length label.
  static String formatChars(int n) {
    if (n < 0) n = 0;
    if (n >= 10000) {
      final wan = n / 10000;
      final s = wan >= 10
          ? wan.toStringAsFixed(0)
          : wan.toStringAsFixed(wan == wan.roundToDouble() ? 0 : 1);
      return '$s万';
    }
    if (n >= 1000) {
      final k = n / 1000;
      return '${k.toStringAsFixed(k == k.roundToDouble() ? 0 : 1)}千';
    }
    return '$n';
  }

  /// Preset targets offered in director setup (0 = unlimited).
  static const presets = <({int chars, String label})>[
    (chars: 0, label: '不限'),
    (chars: 30000, label: '3万'),
    (chars: 50000, label: '5万'),
    (chars: 80000, label: '8万'),
    (chars: 120000, label: '12万'),
    (chars: 200000, label: '20万'),
  ];
}
