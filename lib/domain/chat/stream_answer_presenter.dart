import 'dart:async';

import 'stream_answer_buffer.dart';
import 'stream_ui_coalescer.dart';

class StreamAnswerSnapshot {
  const StreamAnswerSnapshot({
    required this.content,
    required this.reasoning,
    required this.thinkingMillis,
  });
  final String content;
  final String reasoning;
  final int thinkingMillis;
}

/// Publishes accumulated text at the existing per-pane cadence. Persistence and
/// application state remain callbacks owned by the controller.
class StreamAnswerPresenter {
  StreamAnswerPresenter({
    required this.buffer,
    required StreamUiFocus Function() focusOf,
    required this.onPublish,
    required this.onCheckpoint,
    double cacheHitRate = 0,
    DateTime Function()? now,
    this.publishAllChannels = false,
    this.maximumDelay,
  }) : _focusOf = focusOf,
       _now = now ?? DateTime.now,
       _lastCheckpointAt = (now ?? DateTime.now)(),
       _coalescer = DualStreamUiCoalescer(
         cacheHitRate: cacheHitRate,
         focusOf: focusOf,
         now: now,
       );

  static const checkpointInterval = Duration(seconds: 3);
  static const checkpointChars = 8192;

  final StreamAnswerBuffer buffer;
  final bool publishAllChannels;
  final Duration? Function()? maximumDelay;
  final void Function(StreamAnswerSnapshot) onPublish;
  final void Function() onCheckpoint;
  final StreamUiFocus Function() _focusOf;
  final DateTime Function() _now;
  final DualStreamUiCoalescer _coalescer;
  Timer? _flushTimer;
  Duration? _flushDelay;
  bool _dirty = false;
  bool _disposed = false;
  String _publishedContent = '';
  String _publishedReasoning = '';
  DateTime _lastCheckpointAt;
  int _lastCheckpointLength = 0;

  void addReasoning(String text) {
    if (_disposed) return;
    buffer.addReasoning(text);
    _coalescer.addReasoning(text);
  }

  void addContent(String text) {
    if (_disposed) return;
    buffer.addContent(text);
    _coalescer.addContent(text);
  }

  void flush({bool publishAll = false}) {
    if (_disposed) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushDelay = null;
    if (!_dirty && !publishAll) return;
    _dirty = false;
    final focus = _focusOf();
    if (publishAll ||
        publishAllChannels ||
        focus == StreamUiFocus.away ||
        focus == StreamUiFocus.reasoning) {
      _publishedReasoning = buffer.reasoning;
    }
    if (publishAll ||
        publishAllChannels ||
        focus == StreamUiFocus.away ||
        focus == StreamUiFocus.content) {
      _publishedContent = buffer.content;
    }
    _coalescer.markFlushed(all: publishAll || publishAllChannels);
    onPublish(
      StreamAnswerSnapshot(
        content: _publishedContent,
        reasoning: _publishedReasoning,
        thinkingMillis: buffer.thinkingMillis,
      ),
    );

    final totalLength = buffer.totalLength;
    final now = _now();
    if (totalLength > 0 &&
        (now.difference(_lastCheckpointAt) >= checkpointInterval ||
            totalLength - _lastCheckpointLength >= checkpointChars)) {
      _lastCheckpointAt = now;
      _lastCheckpointLength = totalLength;
      onCheckpoint();
    }
  }

  /// Called once after a chunk, including metadata-only chunks.
  void scheduleFlush() {
    if (_disposed) return;
    _dirty = true;
    if (_coalescer.shouldFlushNow) {
      flush();
      return;
    }
    if (!publishAllChannels &&
        _focusOf() != StreamUiFocus.away &&
        !_coalescer.focusedHasPending) {
      return;
    }
    final maximum = maximumDelay?.call();
    final delay = maximum != null && _coalescer.delay > maximum
        ? maximum
        : _coalescer.delay;
    // Answer tokens may need a shorter delay than an existing thinking timer.
    if (_flushTimer != null && _flushDelay != null && delay >= _flushDelay!) {
      return;
    }
    _flushTimer?.cancel();
    _flushDelay = delay;
    _flushTimer = Timer(delay, flush);
  }

  void nudge() {
    if (_disposed) return;
    _dirty = true;
    flush();
  }

  /// The caller flushes before stopping/persisting; disposal never publishes.
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    buffer.stopThinking(recordElapsed: false);
  }
}
