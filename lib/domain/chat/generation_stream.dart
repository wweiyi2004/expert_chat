import 'dart:async';

enum GenerationStreamEnd { completed, cancelled, failed }

class GenerationStreamResult {
  const GenerationStreamResult(this.end, {this.error, this.stackTrace});
  final GenerationStreamEnd end;
  final Object? error;
  final StackTrace? stackTrace;
}

/// Owns one model subscription, including asynchronous cancellation cleanup.
/// A stream result is available only after the subscription has been released.
class GenerationStream {
  final _done = Completer<void>();
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _cleanup;
  GenerationStreamResult? _result;
  bool _started = false;

  void _complete(GenerationStreamResult result) {
    if (_result != null) return;
    _result = result;
    _done.complete();
  }

  void cancel() {
    _complete(const GenerationStreamResult(GenerationStreamEnd.cancelled));
    unawaited(_cancelSubscription());
  }

  Future<void> _cancelSubscription() {
    final subscription = _subscription;
    if (subscription == null) return _cleanup ?? Future<void>.value();
    _subscription = null;
    return _cleanup ??= Future<void>.sync(subscription.cancel).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      // Preserve an explicit cancellation or the original stream failure.
      if (_result?.end == GenerationStreamEnd.completed) {
        _result = GenerationStreamResult(
          GenerationStreamEnd.failed,
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  Future<GenerationStreamResult> consume<T>(
    Stream<T> source, {
    required void Function(T) onData,
  }) async {
    if (_started) throw StateError('A model stream can only be consumed once.');
    _started = true;
    try {
      if (_result == null) {
        _subscription = source.listen(
          (value) {
            if (_result != null) return;
            try {
              onData(value);
            } catch (error, stackTrace) {
              _complete(
                GenerationStreamResult(
                  GenerationStreamEnd.failed,
                  error: error,
                  stackTrace: stackTrace,
                ),
              );
              unawaited(_cancelSubscription());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _complete(
              GenerationStreamResult(
                GenerationStreamEnd.failed,
                error: error,
                stackTrace: stackTrace,
              ),
            );
            unawaited(_cancelSubscription());
          },
          onDone: () {
            // Natural completion has already released the subscription.
            _subscription = null;
            _complete(
              const GenerationStreamResult(GenerationStreamEnd.completed),
            );
          },
        );
      }
      await _done.future;
    } catch (error, stackTrace) {
      _complete(
        GenerationStreamResult(
          GenerationStreamEnd.failed,
          error: error,
          stackTrace: stackTrace,
        ),
      );
    } finally {
      await _cancelSubscription();
    }
    return _result!;
  }
}
