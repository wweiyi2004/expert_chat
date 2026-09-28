import 'dart:async';

import 'package:flutter/foundation.dart';

import 'text_to_speech_service.dart';

/// Uses the cloud speech API when the request carries a usable configuration,
/// otherwise the device speech engine, behind one [playback] listenable.
///
/// Only the service that owns the speaker is forwarded, so stopping the other
/// one cannot flicker the UI. Forwarded request ids are interleaved
/// (cloud even, system odd) so error de-duplication by id stays correct.
class FallbackTextToSpeechService implements TextToSpeechService {
  FallbackTextToSpeechService({required this.cloud, required this.system})
    : _active = cloud {
    cloud.playback.addListener(_forwardCloud);
    system.playback.addListener(_forwardSystem);
  }

  final TextToSpeechService cloud;
  final TextToSpeechService system;
  TextToSpeechService _active;
  bool _disposed = false;
  final ValueNotifier<TextToSpeechPlayback> _playback = ValueNotifier(
    const TextToSpeechPlayback(),
  );

  @override
  ValueListenable<TextToSpeechPlayback> get playback => _playback;

  static bool usesCloud(TextToSpeechRequest request) =>
      request.apiConfig?.isConfiguredWith(request.apiKey) ?? false;

  TextToSpeechService _select(TextToSpeechRequest request) {
    final next = usesCloud(request) ? cloud : system;
    if (!identical(next, _active)) {
      final previous = _active;
      _active = next;
      unawaited(previous.stop());
    }
    return next;
  }

  @override
  Future<void> speak(TextToSpeechRequest request) =>
      _select(request).speak(request);

  @override
  TextToSpeechStream startStream(TextToSpeechRequest request) =>
      _select(request).startStream(request);

  @override
  Future<void> stop() => Future.wait([cloud.stop(), system.stop()]);

  void _forwardCloud() => _forward(cloud, 0);

  void _forwardSystem() => _forward(system, 1);

  void _forward(TextToSpeechService source, int lane) {
    if (_disposed || !identical(source, _active)) return;
    final value = source.playback.value;
    _playback.value = TextToSpeechPlayback(
      phase: value.phase,
      messageId: value.messageId,
      requestId: value.requestId * 2 + lane,
      errorMessage: value.errorMessage,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cloud.playback.removeListener(_forwardCloud);
    system.playback.removeListener(_forwardSystem);
    await Future.wait([cloud.dispose(), system.dispose()]);
    _playback.dispose();
  }
}
