/// Approximate LLM tokens for stream UI coalescing.
///
/// CJK / fullwidth glyphs count as one token each. Latin text is billed at
/// about four characters per token, matching typical BPE packing.
int estimateStreamTokens(String text) {
  if (text.isEmpty) return 0;
  var tokens = 0;
  var latinChars = 0;
  for (final unit in text.codeUnits) {
    final isLatin = unit <= 0x7F;
    if (isLatin) {
      latinChars++;
      continue;
    }
    if (latinChars > 0) {
      tokens += (latinChars + 3) ~/ 4;
      latinChars = 0;
    }
    tokens += 1;
  }
  if (latinChars > 0) tokens += (latinChars + 3) ~/ 4;
  return tokens;
}

/// Batches streaming UI rebuilds so short replies stay live and long replies
/// do not re-parse Markdown on every token.
///
/// First paint is always snappy. After that, the token batch and fallback
/// delay grow with [flushedTokens]. A historical prompt-cache hit rate (or a
/// live high tok/s window, which is how cache hits usually feel) raises the
/// batch so fast completions do not rebuild the bubble 80 times a second.
class StreamUiCoalescer {
  StreamUiCoalescer({this.cacheHitRate = 0, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const int shortBatch = 24;
  static const int longBatch = 120;
  static const int longAfterTokens = 280;
  static const int cacheHitShortBoost = 12;
  static const int cacheHitLongBoost = 40;
  static const double cacheHitRateThreshold = 0.4;
  static const double fastStreamTokensPerSecond = 80;
  static const Duration firstPaintDelay = Duration(milliseconds: 30);
  static const Duration shortFallback = Duration(milliseconds: 70);
  static const Duration longFallback = Duration(milliseconds: 400);
  static const Duration rateWindow = Duration(milliseconds: 200);

  /// Historical prompt-cache hit rate for this endpoint+model, 0..1.
  final double cacheHitRate;
  final DateTime Function() _now;

  int pendingTokens = 0;
  int flushedTokens = 0;
  bool hasFlushed = false;
  double tokensPerSecond = 0;

  DateTime? _rateWindowStart;
  int _rateWindowTokens = 0;

  void add(String text) {
    if (text.isEmpty) return;
    final tokens = estimateStreamTokens(text);
    pendingTokens += tokens;

    final now = _now();
    _rateWindowStart ??= now;
    _rateWindowTokens += tokens;
    final elapsedMs = now.difference(_rateWindowStart!).inMilliseconds;
    if (elapsedMs >= rateWindow.inMilliseconds) {
      tokensPerSecond = _rateWindowTokens * 1000 / elapsedMs;
      _rateWindowStart = now;
      _rateWindowTokens = 0;
    }
  }

  bool get isLikelyFastStream => tokensPerSecond >= fastStreamTokensPerSecond;

  bool get usesCacheHitBatch =>
      cacheHitRate >= cacheHitRateThreshold || isLikelyFastStream;

  int get tokenBatch {
    if (flushedTokens < longAfterTokens) {
      return usesCacheHitBatch ? shortBatch + cacheHitShortBoost : shortBatch;
    }
    return usesCacheHitBatch ? longBatch + cacheHitLongBoost : longBatch;
  }

  /// True once the first frame is on screen and a full token batch is waiting.
  bool get shouldFlushNow => hasFlushed && pendingTokens >= tokenBatch;

  Duration get delay {
    if (!hasFlushed) return firstPaintDelay;
    return flushedTokens < longAfterTokens ? shortFallback : longFallback;
  }

  void markFlushed() {
    flushedTokens += pendingTokens;
    pendingTokens = 0;
    hasFlushed = true;
  }
}

/// Where the user is looking during a live stream.
///
/// Scroll position is the stand-in for gaze: stick-to-bottom follows the
/// growing tail; expanding the thinking panel while scrolled up watches
/// reasoning; anything else is treated as reading a frozen prefix.
enum StreamUiFocus {
  reasoning,
  content,
  away,
}

/// Independent token budgets for the thinking pane and the answer pane.
///
/// A long chain-of-thought must not drag the visible answer into large
/// batches; the answer starts its own short-stream curve when it begins.
/// [focusOf] further limits flushes to the pane in view.
class DualStreamUiCoalescer {
  DualStreamUiCoalescer({
    double cacheHitRate = 0,
    DateTime Function()? now,
    this.focusOf,
  }) : reasoning = StreamUiCoalescer(cacheHitRate: cacheHitRate, now: now),
       content = StreamUiCoalescer(cacheHitRate: cacheHitRate, now: now);

  static const Duration awayFallback = Duration(seconds: 3);

  final StreamUiCoalescer reasoning;
  final StreamUiCoalescer content;
  final StreamUiFocus Function()? focusOf;

  StreamUiFocus get focus => focusOf?.call() ?? StreamUiFocus.content;

  void addReasoning(String text) => reasoning.add(text);

  void addContent(String text) => content.add(text);

  bool get focusedHasPending => switch (focus) {
    StreamUiFocus.away =>
      reasoning.pendingTokens > 0 || content.pendingTokens > 0,
    StreamUiFocus.reasoning => reasoning.pendingTokens > 0,
    StreamUiFocus.content => content.pendingTokens > 0,
  };

  bool get shouldFlushNow => switch (focus) {
    StreamUiFocus.away => false,
    StreamUiFocus.reasoning => reasoning.shouldFlushNow,
    StreamUiFocus.content => content.shouldFlushNow,
  };

  Duration get delay => switch (focus) {
    StreamUiFocus.away => awayFallback,
    StreamUiFocus.reasoning => reasoning.delay,
    StreamUiFocus.content => content.delay,
  };

  void markFlushed({bool all = false}) {
    final publishReasoning =
        all ||
        focus == StreamUiFocus.away ||
        focus == StreamUiFocus.reasoning;
    final publishContent =
        all || focus == StreamUiFocus.away || focus == StreamUiFocus.content;
    if (publishReasoning && (all || reasoning.pendingTokens > 0)) {
      reasoning.markFlushed();
    }
    if (publishContent && (all || content.pendingTokens > 0)) {
      content.markFlushed();
    }
  }
}

/// Scroll-based stand-in for gaze during streaming.
StreamUiFocus streamUiFocusFor({
  required bool followingTail,
  required bool hasContent,
  required bool thinkingExpanded,
}) {
  if (followingTail) {
    return hasContent ? StreamUiFocus.content : StreamUiFocus.reasoning;
  }
  if (thinkingExpanded) return StreamUiFocus.reasoning;
  return StreamUiFocus.away;
}
