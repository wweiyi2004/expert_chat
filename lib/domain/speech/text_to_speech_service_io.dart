import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/media_api_config.dart';
import '../media/openai_compatible_media_provider.dart';
import 'text_to_speech_service.dart';

/// Native implementation of [TextToSpeechService].
///
/// The assistant response is sent to the configured cloud endpoint, then the
/// returned audio is played locally. It never falls back to a device speech
/// engine: missing or invalid API configuration is surfaced to the user
/// directly.
class ApiTextToSpeechService implements TextToSpeechService {
  ApiTextToSpeechService({
    required this.mediaProvider,
    AudioPlayer? initialAudioPlayer,
  }) : _audioPlayer = initialAudioPlayer;

  final OpenAiCompatibleMediaProvider mediaProvider;
  final ValueNotifier<TextToSpeechPlayback> _playback = ValueNotifier(
    const TextToSpeechPlayback(),
  );

  AudioPlayer? _audioPlayer;
  CancelToken? _cancelToken;
  File? _activeAudioFile;
  int _requestId = 0;
  bool _disposed = false;
  bool _tempDirCleaned = false;

  @override
  ValueListenable<TextToSpeechPlayback> get playback => _playback;

  @override
  Future<void> speak(TextToSpeechRequest request) async {
    final text = prepareTextForSpeech(request.text);
    final requestId = ++_requestId;
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

    final config = request.apiConfig;
    if (config == null || !config.isConfiguredWith(request.apiKey)) {
      _setPlayback(
        TextToSpeechPlayback(
          phase: TextToSpeechPhase.error,
          messageId: request.messageId,
          requestId: requestId,
          errorMessage: '请先在设置 > 能力中配置云端语音合成 API。',
        ),
      );
      return;
    }

    _setPlayback(
      TextToSpeechPlayback(
        phase: TextToSpeechPhase.loading,
        messageId: request.messageId,
        requestId: requestId,
      ),
    );
    unawaited(_synthesizeAndPlay(requestId, request, config, text));
  }

  @override
  Future<void> stop() async {
    final requestId = ++_requestId;
    await _stopEngine();
    if (_isCurrent(requestId)) {
      _setPlayback(TextToSpeechPlayback(requestId: requestId));
    }
  }

  Future<void> _synthesizeAndPlay(
    int requestId,
    TextToSpeechRequest request,
    MediaApiConfig config,
    String text,
  ) async {
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    try {
      final player = _ensureAudioPlayer();
      final chunks = splitTextForSpeech(text, maxChunkLength: 3000);
      for (var index = 0; index < chunks.length; index++) {
        if (!_isCurrent(requestId)) return;
        if (index > 0) {
          _setPlayback(
            TextToSpeechPlayback(
              phase: TextToSpeechPhase.loading,
              messageId: request.messageId,
              requestId: requestId,
            ),
          );
        }

        File? audioFile;
        try {
          final audio = await mediaProvider.synthesizeSpeech(
            config: config,
            apiKey: request.apiKey,
            text: chunks[index],
            speed: _cloudSpeedForRate(request.rate),
            cancelToken: cancelToken,
          );
          if (!_isCurrent(requestId)) return;

          audioFile = await _writeAudio(
            audio.bytes,
            requestId,
            index,
            extension: audio.fileExtension,
          );
          if (!_isCurrent(requestId)) return;
          _activeAudioFile = audioFile;

          await player.setFilePath(audioFile.path);
          if (!_isCurrent(requestId)) return;
          _setPlayback(
            TextToSpeechPlayback(
              phase: TextToSpeechPhase.speaking,
              messageId: request.messageId,
              requestId: requestId,
            ),
          );
          await player.play();
        } finally {
          if (identical(_activeAudioFile, audioFile)) {
            _activeAudioFile = null;
          }
          await _deleteAudioFile(audioFile);
        }
      }
      if (_isCurrent(requestId)) {
        _setPlayback(TextToSpeechPlayback(requestId: requestId));
      }
    } on DioException catch (error) {
      if (!_isCurrent(requestId)) return;
      if (CancelToken.isCancel(error)) {
        // The provider aborts oversized audio by cancelling the shared token.
        // Match its reason to tell that internal abort apart from a
        // user-initiated stop; a user stop must stay silent (the stop() call
        // already reset playback to idle).
        final reason = error.error;
        if (reason is String &&
            reason == OpenAiCompatibleMediaProvider.ttsSizeLimitCancelReason) {
          _setPlayback(
            _apiErrorPlayback(request, requestId, FormatException(reason)),
          );
        }
        return;
      }
      _setPlayback(_apiErrorPlayback(request, requestId, error));
    } on FormatException catch (error) {
      if (!_isCurrent(requestId)) return;
      _setPlayback(_apiErrorPlayback(request, requestId, error));
    } catch (error) {
      if (!_isCurrent(requestId)) return;
      _setPlayback(_apiErrorPlayback(request, requestId, error));
    } finally {
      if (identical(_cancelToken, cancelToken)) {
        _cancelToken = null;
      }
    }
  }

  TextToSpeechPlayback _apiErrorPlayback(
    TextToSpeechRequest request,
    int requestId,
    Object error,
  ) {
    final detail = _errorDetail(error);
    return TextToSpeechPlayback(
      phase: TextToSpeechPhase.error,
      messageId: request.messageId,
      requestId: requestId,
      errorMessage: detail == null
          ? '云端语音播放失败，请检查 API 配置和网络后重试。'
          : '云端语音合成失败：$detail',
    );
  }

  /// Extracts a user-facing detail from an error the media provider threw.
  ///
  /// The provider already humanizes DioExceptions into plain
  /// `Exception('语音生成失败（401）：请检查 API Key。')` instances; the fixed
  /// "check your configuration" copy would swallow that detail, so prefer the
  /// exception's own message and fall back to the generic copy only when no
  /// usable detail exists.
  String? _errorDetail(Object error) {
    if (error is FormatException) {
      final message = error.message.trim();
      return message.isEmpty ? null : message;
    }
    if (error is DioException) {
      final message = error.message?.trim() ?? '';
      return message.isEmpty ? null : message;
    }
    if (error is Exception) {
      // dart:core Exception only exposes its constructor message through
      // toString() ("Exception: <message>"), so strip that prefix.
      final text = error.toString();
      const prefix = 'Exception: ';
      final message = text.startsWith(prefix)
          ? text.substring(prefix.length).trim()
          : text.trim();
      return message.isEmpty ? null : message;
    }
    return null;
  }

  AudioPlayer _ensureAudioPlayer() => _audioPlayer ??= AudioPlayer();

  double _cloudSpeedForRate(double localRate) {
    final normalizedLocalRate = localRate.clamp(0.2, 0.8).toDouble();
    return (normalizedLocalRate / 0.5).clamp(0.25, 4.0).toDouble();
  }

  Future<File> _writeAudio(
    Uint8List bytes,
    int requestId,
    int chunkIndex, {
    required String extension,
  }) async {
    final cache = await getTemporaryDirectory();
    final directory = Directory(
      '${cache.path}${Platform.pathSeparator}expert-chat-tts',
    );
    await directory.create(recursive: true);
    if (!_tempDirCleaned) {
      // Clear leftovers of previous sessions once per service lifetime, right
      // before the first write: nothing is being played at that point, so a
      // stale file can never be the one currently on the audio stack.
      _tempDirCleaned = true;
      await cleanupStaleAudioFiles(directory);
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'speech-$requestId-$chunkIndex.${_safeExtension(extension)}',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  String _safeExtension(String raw) {
    final normalized = raw.trim().toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(normalized) ? normalized : 'mp3';
  }

  Future<void> _stopEngine() async {
    _cancelToken?.cancel('朗读已停止');
    _cancelToken = null;
    try {
      await _audioPlayer?.stop();
    } catch (_) {
      // Stopping an already-complete player is safe.
    }

    final audioFile = _activeAudioFile;
    _activeAudioFile = null;
    await _deleteAudioFile(audioFile);
  }

  Future<void> _deleteAudioFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Some Windows audio drivers release a file just after stop(). Keeping a
      // temp file is safer than disrupting the next narration request.
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
    await _stopEngine();
    try {
      await _audioPlayer?.dispose();
    } catch (_) {
      // Player disposal is best effort during app shutdown.
    }
    _playback.dispose();
  }
}

/// Deletes audio files left in [directory] by previous sessions so the temp
/// directory does not accumulate speech files across launches.
///
/// Best effort: a file still held by the audio stack (some Windows drivers
/// release a file just after stop()) is skipped rather than retried - leaving
/// one stale file is safer than disrupting playback. Never throws.
Future<void> cleanupStaleAudioFiles(Directory directory) async {
  try {
    if (!await directory.exists()) return;
    await for (final entry in directory.list()) {
      if (entry is! File) continue;
      try {
        await entry.delete();
      } catch (_) {
        // A locked file is safe to leave for a later session to retry.
      }
    }
  } catch (_) {
    // A failed cleanup must never block the write that follows it.
  }
}
