import 'package:characters/characters.dart';

import '../../data/models.dart';

/// Computes written length and soft pacing guidance for story sessions.
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
    required this.currentBeatTarget,
    required this.currentBeatEndTarget,
    required this.currentBeatRemaining,
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

  /// Planned size of the current beat.
  final int currentBeatTarget;

  /// Cumulative whole-book character threshold at which this beat is complete.
  final int currentBeatEndTarget;

  /// Characters still needed before the current beat should advance.
  final int currentBeatRemaining;

  /// Alias used by existing UI: characters still to write for the current beat.
  final int perBeatSuggest;

  /// Soft band for **this turn's** output length.
  final int turnMin;
  final int turnMax;

  /// 0..1 completion vs target (clamped).
  final double progressRatio;

  bool get hasTarget => targetTotal > 0;

  bool get targetReached => hasTarget && written >= targetTotal;

  /// Progress signal retained for UI compatibility. Scene advancement must not
  /// depend on this estimate; a beat ends when its dramatic objective ends.
  bool get currentBeatTargetReached =>
      beatCount > 0 &&
      plotCursor < beatCount &&
      written >= currentBeatEndTarget;

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
    final cursor = conversation.plotCursor.clamp(
      0,
      beatCount == 0 ? 0 : beatCount,
    );
    // Include the current unfinished beat in the remaining denominator. Once
    // the cursor has advanced past every beat there is none left — clamping
    // the 0 to 1 would claim "1 beat left" while the outline is fully done.
    final beatsLeft = beatCount == 0
        ? 1
        : (beatCount - cursor).clamp(0, beatCount);

    final int beatStartTarget;
    final int beatEndTarget;
    final int currentBeatTarget;
    final int currentBeatRemaining;
    if (beatCount > 0 && cursor < beatCount) {
      beatStartTarget = (target * cursor / beatCount).round();
      beatEndTarget = (target * (cursor + 1) / beatCount).round();
      currentBeatTarget = (beatEndTarget - beatStartTarget).clamp(0, target);
      currentBeatRemaining = (beatEndTarget - written).clamp(0, remaining);
    } else {
      beatStartTarget = written;
      beatEndTarget = target;
      currentBeatTarget = remaining;
      currentBeatRemaining = remaining;
    }
    final perBeat = currentBeatRemaining;

    // Offer a comfortable per-turn range. It is planning guidance only: models
    // cannot reliably count exact characters, and scene integrity comes first.
    //
    // Dart's num.clamp(lower, upper) requires lower <= upper. Near the end of a
    // long novel, remaining can be < 200; never pass a lower bound above it.
    final int turnMin;
    final int turnMax;
    final turnQuota = currentBeatRemaining > 0
        ? currentBeatRemaining
        : remaining;
    if (remaining <= 0 || turnQuota <= 0) {
      turnMin = 0;
      turnMax = 0;
    } else if (turnQuota < 900) {
      final softMin = (turnQuota * 0.6).round();
      // Prefer ~60% of what's left, but never exceed remaining and never use
      // clamp(200, remaining) when remaining < 200 (throws ArgumentError).
      final minV = softMin.clamp(1, turnQuota);
      turnMin = minV;
      turnMax = turnQuota;
    } else {
      final center = (turnQuota * 0.5).round().clamp(900, 4000);
      final cappedCenter = center > turnQuota ? turnQuota : center;
      var minV = (cappedCenter * 0.75).round().clamp(1, turnQuota);
      var maxV = (cappedCenter * 1.2).round();
      if (maxV > turnQuota) maxV = turnQuota;
      if (maxV > 5000) maxV = turnQuota < 5000 ? turnQuota : 5000;
      if (minV > maxV) {
        minV = maxV < 1 ? 1 : (maxV * 0.75).round().clamp(1, maxV);
      }
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
      currentBeatTarget: currentBeatTarget,
      currentBeatEndTarget: beatEndTarget,
      currentBeatRemaining: currentBeatRemaining,
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
      parts.add('本拍参考余量${formatChars(perBeatSuggest)}');
    }
    if (turnMax > 0) {
      parts.add('本回合${formatChars(turnMin)}–${formatChars(turnMax)}');
    }
    return parts.join(' · ');
  }

  /// Soft pacing block injected into the story system prompt.
  String promptBlock({required bool advancePlot}) {
    final b = StringBuffer()
      ..writeln('【篇幅与节奏参考 · 软目标】')
      ..writeln(
        '全书目标约 ${formatChars(targetTotal)}字；'
        '目前已写约 ${formatChars(written)}字'
        '（完成 ${(progressRatio * 100).toStringAsFixed(0)}%），'
        '剩余约 ${formatChars(remaining)}字。',
      );

    if (beatCount > 0) {
      final beatNo = plotCursor < beatCount ? plotCursor + 1 : beatCount;
      final leftPhrase = beatsLeft == 0 ? '已无剩余节拍；' : '剩余约 $beatsLeft 拍（含当前）；';
      b.writeln(
        '大纲共 $beatCount 拍，当前第 $beatNo 拍；'
        '$leftPhrase'
        '若按平均分配，本拍约 ${formatChars(currentBeatTarget)}字，'
        '按全书累计进度参考尚余 ${formatChars(currentBeatRemaining)}字。',
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
            ? '本回合建议约 ${formatChars(turnMin)}–${formatChars(turnMax)}字。'
                  '以完成当前场景目标和自然收束为准，可合理短于或超过该范围；'
                  '不要为了接近字数而重复情节、堆砌描写或拆断完整场景。'
            : '本回合建议约 ${formatChars(turnMin)}–${formatChars(turnMax)}字。'
                  '执行导演指令并推进必要情节；场景完整性优先，不为凑字数注水。',
      );
    }

    b.write('篇幅仅用于全书节奏校准，不决定节拍是否完成。');
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
