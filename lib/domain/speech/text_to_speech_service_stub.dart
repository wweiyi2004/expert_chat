import 'package:flutter/foundation.dart';

import '../media/openai_compatible_media_provider.dart';
import 'text_to_speech_service.dart';

/// Browser implementation of [TextToSpeechService].
///
/// There is no local audio-file pipeline to play cloud-synthesized audio
/// through, so speaking reports an explicit unsupported-platform error
/// instead of the misleading "check your API configuration" message the
/// native failure path would produce. The provider argument is accepted for
/// call-site compatibility but unused.
class ApiTextToSpeechService implements TextToSpeechService {
  ApiTextToSpeechService({OpenAiCompatibleMediaProvider? mediaProvider});

  final ValueNotifier<TextToSpeechPlayback> _playback = ValueNotifier(
    const TextToSpeechPlayback(),
  );
  int _requestId = 0;
  bool _disposed = false;

  @override
  ValueListenable<TextToSpeechPlayback> get playback => _playback;

  @override
  Future<void> speak(TextToSpeechRequest request) async {
    final requestId = ++_requestId;
    _setPlayback(
      TextToSpeechPlayback(
        phase: TextToSpeechPhase.error,
        messageId: request.messageId,
        requestId: requestId,
        errorMessage: '当前平台不支持语音朗读。',
      ),
    );
  }

  @override
  Future<void> stop() async {
    final requestId = ++_requestId;
    _setPlayback(TextToSpeechPlayback(requestId: requestId));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playback.dispose();
  }

  void _setPlayback(TextToSpeechPlayback value) {
    if (!_disposed) _playback.value = value;
  }
}
