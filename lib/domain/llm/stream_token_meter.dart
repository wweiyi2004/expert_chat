import 'dart:collection';
import 'dart:async';
import 'llm_provider.dart';

/// Ephemeral transport measurements; never model context or billing evidence.
class StreamTokenMeter {
  StreamTokenMeter(this.inputEstimate);
  static final latest = <String, StreamTokenMeter>{};
  final int inputEstimate;
  final clock = Stopwatch()..start();
  final samples = Queue<(double, double)>();
  double output = 0;
  double? uploadStart;
  int uploadBase = 0;
  double? uploadRate;
  bool active = true;
  static StreamTokenMeter begin(String session, int input) {
    if (latest.length >= 256) latest.remove(latest.keys.first);
    return latest[session] = StreamTokenMeter(input);
  }

  void upload(int count, int total) {
    if (total <= 0 || count <= 0) return;
    final seconds = clock.elapsedMicroseconds / 1000000;
    if (uploadStart == null) {
      uploadStart = seconds;
      uploadBase = count;
      return;
    }
    final elapsed = seconds - uploadStart!;
    if (elapsed >= .01 && count > uploadBase) {
      uploadRate = inputEstimate * (count - uploadBase) / total / elapsed;
    }
  }

  void chunk(ChatChunk chunk) {
    final text = '${chunk.contentDelta ?? ''}${chunk.reasoningDelta ?? ''}';
    if (text.isEmpty) return;
    final seconds = clock.elapsedMicroseconds / 1000000;
    if (samples.isEmpty) samples.add((seconds, output));
    for (final rune in text.runes) {
      output += rune <= 127 ? .25 : 1;
    }
    samples.add((seconds, output));
    while (samples.length > 2 &&
        (seconds - samples.elementAt(1).$1 > 5 || samples.length > 2048)) {
      samples.removeFirst();
    }
  }

  Map<String, Object?> snapshot() {
    final now = clock.elapsedMicroseconds / 1000000;
    final duration = samples.isEmpty ? 0.0 : now - samples.first.$1;
    final idle = samples.isEmpty || now - samples.last.$1 > 3;
    return {
      'upload_tps': active ? uploadRate : null,
      'download_tps': !active || samples.isEmpty || duration < .25
          ? null
          : idle
          ? 0.0
          : (output - samples.first.$2) / duration,
      'estimated': true,
      'active': active,
    };
  }

  void _finish() {
    active = false;
    clock.stop();
  }

  Stream<ChatChunk> watch(Stream<ChatChunk> stream) =>
      _MeteredStream(stream, this);
}

/// A transparent subscription adapter: no async generator or intermediate
/// controller can delay cancellation or the source's completion callback.
class _MeteredStream extends Stream<ChatChunk> {
  _MeteredStream(this.source, this.meter);
  final Stream<ChatChunk> source;
  final StreamTokenMeter meter;
  @override
  bool get isBroadcast => source.isBroadcast;
  @override
  StreamSubscription<ChatChunk> listen(
    void Function(ChatChunk)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final inner = source.listen(
      (value) {
        meter.chunk(value);
        onData?.call(value);
      },
      onError: onError,
      onDone: () {
        meter._finish();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    return _MeteredSubscription(inner, meter);
  }
}

class _MeteredSubscription implements StreamSubscription<ChatChunk> {
  _MeteredSubscription(this.inner, this.meter);
  final StreamSubscription<ChatChunk> inner;
  final StreamTokenMeter meter;
  @override
  Future<void> cancel() {
    meter._finish();
    return inner.cancel();
  }

  @override
  void onData(void Function(ChatChunk)? handler) => inner.onData((value) {
    meter.chunk(value);
    handler?.call(value);
  });
  @override
  void onError(Function? handler) => inner.onError(handler);
  @override
  void onDone(void Function()? handler) => inner.onDone(() {
    meter._finish();
    handler?.call();
  });
  @override
  void pause([Future<void>? resumeSignal]) => inner.pause(resumeSignal);
  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) =>
      inner.asFuture<E>(futureValue).whenComplete(meter._finish);
}
