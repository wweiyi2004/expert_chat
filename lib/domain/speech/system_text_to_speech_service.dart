import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'text_to_speech_service.dart';

/// One utterance at a time on the device speech engine.
abstract class SystemSpeechEngine {
  /// Speaks [text] and completes when it finished or was stopped. Throws
  /// [SystemSpeechException] when the engine refuses or fails the utterance.
  Future<void> speak(String text, {required double rate});

  /// Interrupts the current utterance; its [speak] future then completes.
  Future<void> stop();
}

class SystemSpeechException implements Exception {
  const SystemSpeechException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [SystemSpeechEngine] backed by flutter_tts (Android TextToSpeech, AVSpeech,
/// SAPI). Completion comes from the platform callbacks rather than
/// `awaitSpeakCompletion`, whose behaviour on stop differs by platform.
class FlutterTtsEngine implements SystemSpeechEngine {
  FlutterTts? _tts;
  Completer<void>? _utterance;
  double? _rate;

  FlutterTts _ensure() {
    final existing = _tts;
    if (existing != null) return existing;
    final tts = FlutterTts()
      ..setCompletionHandler(_finish)
      ..setCancelHandler(_finish)
      ..setErrorHandler((message) {
        _finish(SystemSpeechException('系统语音朗读失败：$message'));
      });
    unawaited(tts.awaitSpeakCompletion(false));
    // Best effort: a device without Chinese voice data keeps its default.
    unawaited(
      Future<void>(() => tts.setLanguage('zh-CN')).catchError((Object _) {}),
    );
    return _tts = tts;
  }

  @override
  Future<void> speak(String text, {required double rate}) async {
    final tts = _ensure();
    if (_rate != rate) {
      _rate = rate;
      await tts.setSpeechRate(rate);
    }
    _finish();
    final utterance = _utterance = Completer<void>();
    final started = await tts.speak(text);
    if (started != 1 && !utterance.isCompleted) {
      _finish(const SystemSpeechException('手机没有可用的系统语音引擎，请在系统设置中安装或启用文字转语音。'));
    }
    return utterance.future;
  }

  @override
  Future<void> stop() async {
    try {
      await _tts?.stop();
    } finally {
      _finish();
    }
  }

  void _finish([Object? error]) {
    final utterance = _utterance;
    _utterance = null;
    if (utterance == null || utterance.isCompleted) return;
    if (error == null) {
      utterance.complete();
    } else {
      utterance.completeError(error);
    }
  }
}

/// Reads replies aloud with the device speech engine. Used when no cloud
/// speech API is configured, so read-aloud and voice conversation work with
/// zero setup (lower voice quality, no emotion styling).
class SystemTextToSpeechService implements TextToSpeechService {
  SystemTextToSpeechService({SystemSpeechEngine? engine})
    : _engine = engine ?? FlutterTtsEngine();

  final SystemSpeechEngine _engine;
  final ValueNotifier<TextToSpeechPlayback> _playback = ValueNotifier(
    const TextToSpeechPlayback(),
  );
  SpeechChunkQueue? _activeQueue;
  int _requestId = 0;
  bool _disposed = false;

  @override
  ValueListenable<TextToSpeechPlayback> get playback => _playback;

  @override
  Future<void> speak(TextToSpeechRequest request) async {
    final text = prepareTextForSpeech(request.text);
    final requestId = ++_requestId;
    _retireQueue();
    await _stopEngine();
    if (!_isCurrent(requestId)) return;
    if (text.isEmpty) {
      _setPlayback(
        TextToSpeechPlayback(
          phase: TextToSpeechPhase.error,
          messageId: request.messageId,
          requestId: requestId,
          errorMessage: '这条消息没有可朗读的文本。',
        ),
      );
      return;
    }
    final queue = SpeechChunkQueue()
      ..append(request.text)
      ..close();
    _activeQueue = queue;
    unawaited(_play(requestId, request, queue));
  }

  @override
  TextToSpeechStream startStream(TextToSpeechRequest request) {
    final queue = SpeechChunkQueue()..append(request.text);
    final requestId = ++_requestId;
    _retireQueue();
    _activeQueue = queue;
    unawaited(() async {
      await _stopEngine();
      if (!_isCurrent(requestId)) {
        queue.finish(false);
        return;
      }
      await _play(requestId, request, queue);
    }());
    return queue;
  }

  Future<void> _play(
    int requestId,
    TextToSpeechRequest request,
    SpeechChunkQueue queue,
  ) async {
    TextToSpeechPlayback phase(TextToSpeechPhase value) => TextToSpeechPlayback(
      phase: value,
      messageId: request.messageId,
      requestId: requestId,
    );
    var completed = false;
    try {
      _setPlayback(phase(TextToSpeechPhase.loading));
      for (var index = 0; ; index++) {
        if (!_isCurrent(requestId)) return;
        if (index >= queue.length && !queue.isClosed) {
          _setPlayback(phase(TextToSpeechPhase.loading));
          await queue.waitFor(index);
          if (!_isCurrent(requestId)) return;
        }
        if (index >= queue.length) break;
        _setPlayback(phase(TextToSpeechPhase.speaking));
        await _engine.speak(queue[index], rate: request.rate);
      }
      if (_isCurrent(requestId)) {
        completed = true;
        _setPlayback(TextToSpeechPlayback(requestId: requestId));
      }
    } catch (error) {
      if (!_isCurrent(requestId)) return;
      _setPlayback(
        TextToSpeechPlayback(
          phase: TextToSpeechPhase.error,
          messageId: request.messageId,
          requestId: requestId,
          errorMessage: error is SystemSpeechException
              ? error.message
              : '系统语音朗读失败，请检查手机的文字转语音设置。',
        ),
      );
    } finally {
      queue.finish(completed);
    }
  }

  @override
  Future<void> stop() async {
    final requestId = ++_requestId;
    _retireQueue();
    await _stopEngine();
    if (_isCurrent(requestId)) {
      _setPlayback(TextToSpeechPlayback(requestId: requestId));
    }
  }

  void _retireQueue() {
    _activeQueue?.cancel();
    _activeQueue = null;
  }

  Future<void> _stopEngine() async {
    try {
      await _engine.stop();
    } catch (_) {
      // Nothing was speaking, or the engine is unavailable; both are fine here.
    }
  }

  bool _isCurrent(int requestId) => !_disposed && requestId == _requestId;

  void _setPlayback(TextToSpeechPlayback value) {
    if (!_disposed) _playback.value = value;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_requestId;
    _retireQueue();
    await _stopEngine();
    _playback.dispose();
  }
}
