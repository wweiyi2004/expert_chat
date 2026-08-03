import 'dart:async';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/media_api_config.dart';
import '../media/openai_compatible_media_provider.dart';
import 'speech_style_analyzer.dart';
import 'text_to_speech_service.dart';

/// Native implementation of [TextToSpeechService].
///
/// The assistant response is sent to the configured cloud endpoint, then the
/// returned audio is played locally. It never falls back to a device speech
/// engine: missing or invalid API configuration is surfaced to the user
/// directly.
///
/// Long replies are split into sentence-sized chunks and synthesized with a
/// small prefetch window: while sentence N is speaking, N+1 and N+2 are already
/// downloading so the listener rarely waits between sentences.
class ApiTextToSpeechService implements TextToSpeechService {
  ApiTextToSpeechService({
    required this.mediaProvider,
    AudioPlayer? initialAudioPlayer,
  }) : _audioPlayer = initialAudioPlayer;

  final OpenAiCompatibleMediaProvider mediaProvider;
  final ValueNotifier<TextToSpeechPlayback> _playback = ValueNotifier(
    const TextToSpeechPlayback(),
  );

  /// Hard cap for a single synthesis request. Sentences longer than this are
  /// split further; normal sentences stay one-chunk-one-request.
  @visibleForTesting
  static const int speechChunkLength = 280;

  /// How many upcoming sentences to synthesize while the current one plays.
  /// "读一句，预载两句" → keep two chunks ahead of the play head.
  @visibleForTesting
  static const int prefetchAhead = 2;

  AudioPlayer? _audioPlayer;
  CancelToken? _cancelToken;
  File? _activeAudioFile;

  /// Prefetched (and still-playing) temp files that must be deleted on stop.
  final Set<File> _ownedAudioFiles = {};
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
          errorMessage:
              '请先在设置 → 能力 → 云端语音合成中填写 Base URL、模型和 API Key'
              '（与聊天 API 相互独立；MiMo 请用「切换到 MiMo TTS」）。',
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
      // One sentence per chunk so playback can overlap with look-ahead
      // downloads (packSentences: false). Oversized sentences still split.
      final chunks = splitTextForSpeech(
        text,
        maxChunkLength: speechChunkLength,
        packSentences: false,
      );
      if (chunks.isEmpty) {
        if (_isCurrent(requestId)) {
          _setPlayback(TextToSpeechPlayback(requestId: requestId));
        }
        return;
      }

      final speed = _cloudSpeedForRate(request.rate);
      // Load the clone sample once for the whole utterance (not per sentence).
      final cloneSample = await _loadVoiceCloneSample(config);
      if (!_isCurrent(requestId)) return;
      // index → in-flight or completed synthesis of that sentence.
      final pending = <int, Future<_PreparedChunk>>{};
      // Chunks whose Future has already resolved successfully.
      final readyFiles = <int, File>{};

      Future<_PreparedChunk> enqueue(int index) {
        return pending.putIfAbsent(index, () async {
          final file = await _synthesizeChunkToFile(
            requestId: requestId,
            request: request,
            config: config,
            text: chunks[index],
            chunkIndex: index,
            speed: speed,
            cancelToken: cancelToken,
            cloneSample: cloneSample,
          );
          readyFiles[index] = file;
          return _PreparedChunk(index: index, file: file);
        });
      }

      void ensurePrefetchThrough(int playIndex) {
        // Keep [prefetchAhead] sentences ahead of the one about to play / playing.
        final last = (playIndex + prefetchAhead).clamp(0, chunks.length - 1);
        for (var i = playIndex; i <= last; i++) {
          if (pending.containsKey(i)) continue;
          // Attach an onError so a failed look-ahead is not an unhandled async
          // error; the same Future stays in [pending] for the play loop to await.
          unawaited(
            enqueue(i).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          );
        }
      }

      // Prime: sentence 0 plus look-ahead before the first await.
      ensurePrefetchThrough(0);

      for (var index = 0; index < chunks.length; index++) {
        if (!_isCurrent(requestId)) return;

        // Top up the window as the play head advances.
        ensurePrefetchThrough(index);

        // Between sentences, only show loading if the next file is not ready
        // yet (prefetch lagged). First sentence already shows loading from speak().
        final fileFuture = enqueue(index);
        if (index > 0 && !readyFiles.containsKey(index)) {
          _setPlayback(
            TextToSpeechPlayback(
              phase: TextToSpeechPhase.loading,
              messageId: request.messageId,
              requestId: requestId,
            ),
          );
        }

        final prepared = await fileFuture;
        if (!_isCurrent(requestId)) return;

        // Start the next look-ahead while this file is on the speaker.
        // Prefetch only downloads; playback below stays strictly sequential.
        ensurePrefetchThrough(index + 1);

        final audioFile = prepared.file;
        _activeAudioFile = audioFile;
        _setPlayback(
          TextToSpeechPlayback(
            phase: TextToSpeechPhase.speaking,
            messageId: request.messageId,
            requestId: requestId,
          ),
        );
        // Must wait until THIS sentence fully finishes before loading the next
        // path. On Windows, just_audio's play() future often resolves as soon
        // as playback starts, which previously raced the loop to the last
        // sentence mid-utterance.
        await _playFileToCompletion(player, audioFile, requestId);
        if (!_isCurrent(requestId)) return;

        if (identical(_activeAudioFile, audioFile)) {
          _activeAudioFile = null;
        }
        readyFiles.remove(index);
        pending.remove(index);
        _ownedAudioFiles.remove(audioFile);
        await _deleteAudioFile(audioFile);
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

  /// Downloads one sentence and writes it to a temp file owned by this service.
  Future<File> _synthesizeChunkToFile({
    required int requestId,
    required TextToSpeechRequest request,
    required MediaApiConfig config,
    required String text,
    required int chunkIndex,
    required double speed,
    required CancelToken cancelToken,
    _VoiceCloneSample? cloneSample,
  }) async {
    final chunkConfig = _configWithChunkStyle(
      config: config,
      chunkText: text,
      speed: speed,
      autoEmotion: request.autoEmotion,
    );
    final audio = await mediaProvider.synthesizeSpeech(
      config: chunkConfig,
      apiKey: request.apiKey,
      text: text,
      speed: speed,
      cancelToken: cancelToken,
      voiceSampleBytes: cloneSample?.bytes,
      voiceSampleMimeType: cloneSample?.mimeType ?? 'audio/wav',
    );
    if (!_isCurrent(requestId)) {
      // Request was superseded; cancel-shaped so the play loop exits quietly.
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: '朗读已停止',
      );
    }
    final file = await _writeAudio(
      audio.bytes,
      requestId,
      chunkIndex,
      extension: audio.fileExtension,
    );
    if (!_isCurrent(requestId)) {
      await _deleteAudioFile(file);
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: '朗读已停止',
      );
    }
    _ownedAudioFiles.add(file);
    return file;
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

  /// Plays [file] from the start and does not return until it has finished
  /// (or the request is cancelled / the player is stopped).
  ///
  /// just_audio documents that [AudioPlayer.play] completes when playback
  /// ends, but just_audio_windows frequently completes that future when
  /// playback *starts*. Relying on it alone made the sentence loop jump
  /// ahead and cut the current utterance short.
  ///
  /// A second Windows quirk: just_audio_windows maps
  /// `Position == NaturalDuration` to [ProcessingState.completed], and both
  /// values are often still 0 right after [AudioPlayer.setFilePath]. Treating
  /// that as "already finished" skips [AudioPlayer.play] entirely — synthesis
  /// succeeds, the UI flips through sentences, and the user hears silence.
  Future<void> _playFileToCompletion(
    AudioPlayer player,
    File file,
    int requestId,
  ) async {
    // Reset the player between sentences. Pause, never stop: just_audio's
    // stop() tears the native platform down (and WinRT reports every finished
    // sentence as idle, which just_audio 0.10.x also turns into a teardown),
    // so stop() between sentences races the just_audio_windows backend with
    // create/destroy cycles. Pausing keeps the player warm; the next
    // setFilePath simply replaces the source.
    try {
      await player.pause();
    } catch (_) {
      // A paused/idle player is fine.
    }
    if (!_isCurrent(requestId)) return;

    var duration = await player.setFilePath(file.path);
    if (!_isCurrent(requestId)) return;

    // Always restart from the beginning. A leftover position from the previous
    // sentence (or a false completed at 0:0) must not short-circuit play().
    try {
      await player.seek(Duration.zero);
    } catch (_) {
      // Some platforms reject seek before the first play; play() still works.
    }
    if (!_isCurrent(requestId)) return;

    // Prefer a duration that is actually usable. just_audio_windows often
    // returns Duration.zero from load before NaturalDuration is known.
    duration = _usableDuration(duration) ?? _usableDuration(player.duration);

    final finished = Completer<void>();
    void completeOnce() {
      if (!finished.isCompleted) finished.complete();
    }

    // End-of-speech is only trusted after play() has been issued and we have
    // evidence that audio actually started, so a load-time false
    // "completed"/"idle" cannot skip the utterance.
    var playIssued = false;
    var playbackObserved = false;
    var playIssuedAt = DateTime.now();

    bool isReliableEnd(PlayerState state) {
      if (!playIssued) return false;
      if (state.playing) playbackObserved = true;
      final elapsed = DateTime.now().difference(playIssuedAt);
      // Give the native layer a beat to leave the post-load false completed.
      if (!playbackObserved && elapsed < const Duration(milliseconds: 150)) {
        return false;
      }

      final knownDuration =
          _usableDuration(duration) ?? _usableDuration(player.duration);
      final position = player.position;

      if (state.processingState == ProcessingState.completed) {
        // Windows: position==duration==0 after load is NOT completion.
        if (knownDuration == null &&
            position <= const Duration(milliseconds: 50)) {
          return false;
        }
        if (knownDuration != null &&
            position + const Duration(milliseconds: 120) < knownDuration &&
            !playbackObserved) {
          return false;
        }
        return playbackObserved || elapsed >= const Duration(milliseconds: 150);
      }

      if (state.processingState == ProcessingState.idle) {
        // WinRT has no terminal "completed"; a finished clip falls back to
        // None→idle. Only honor that after real playback, otherwise a
        // pre-play idle would end the sentence silently.
        return playbackObserved;
      }
      return false;
    }

    late final StreamSubscription<PlayerState> stateSubscription;
    stateSubscription = player.playerStateStream.listen((state) {
      if (isReliableEnd(state)) completeOnce();
    });

    StreamSubscription<Duration>? positionSubscription;
    positionSubscription = player.positionStream.listen((position) {
      if (!playIssued) return;
      if (position > const Duration(milliseconds: 30)) {
        playbackObserved = true;
      }
      final knownDuration =
          _usableDuration(duration) ?? _usableDuration(player.duration);
      if (knownDuration != null &&
          position + const Duration(milliseconds: 80) >= knownDuration &&
          playbackObserved) {
        completeOnce();
      }
    });

    try {
      // Never skip play() based on a pre-existing completed/idle state —
      // that is the Windows no-sound failure mode.
      playIssued = true;
      playIssuedAt = DateTime.now();
      if (!player.playing) {
        await player.play();
      }
      if (!_isCurrent(requestId)) return;

      // play() may resolve as soon as native playback starts (Windows). Re-read
      // duration now that the media pipeline is open, then wait for a real end.
      duration = _usableDuration(duration) ?? _usableDuration(player.duration);

      if (player.playing) playbackObserved = true;
      if (isReliableEnd(player.playerState)) completeOnce();

      if (!finished.isCompleted) {
        final watch = finished.future;
        final knownDuration = _usableDuration(duration);
        if (knownDuration != null) {
          await Future.any<void>([
            watch,
            // Hard ceiling slightly past the declared duration so a lost end
            // event cannot stall the sentence loop forever.
            Future<void>.delayed(
              knownDuration + const Duration(milliseconds: 750),
            ),
          ]);
        } else {
          // Unknown duration: idle/completed (after real playback) is the
          // primary end marker; the timeout is only a final guard.
          await watch.timeout(const Duration(minutes: 3), onTimeout: () {});
        }
      }
    } finally {
      await stateSubscription.cancel();
      await positionSubscription.cancel();
      // Leave the player paused so the next sentence starts cleanly.
      if (_isCurrent(requestId)) {
        try {
          await player.pause();
        } catch (_) {
          // Best effort between sentences.
        }
      }
    }
  }

  /// Returns [duration] only when it is long enough to be a real media length.
  ///
  /// just_audio_windows commonly reports [Duration.zero] before WinRT has
  /// resolved [NaturalDuration]; treating that as "already finished" is what
  /// produced silent "playback".
  Duration? _usableDuration(Duration? duration) {
    if (duration == null) return null;
    if (duration <= const Duration(milliseconds: 50)) return null;
    return duration;
  }

  double _cloudSpeedForRate(double localRate) {
    final normalizedLocalRate = localRate.clamp(0.2, 0.8).toDouble();
    return (normalizedLocalRate / 0.5).clamp(0.25, 4.0).toDouble();
  }

  /// Builds a per-sentence config whose style instruction matches [chunkText].
  ///
  /// Auto-emotion is merged with any user/persona prompt already on [config]
  /// so a fixed 自制音色 still reacts to happy vs sad lines.
  MediaApiConfig _configWithChunkStyle({
    required MediaApiConfig config,
    required String chunkText,
    required double speed,
    required bool autoEmotion,
  }) {
    final protocol = config.effectiveSpeechProtocol;
    if (protocol != SpeechApiProtocol.mimoChatCompletions &&
        protocol != SpeechApiProtocol.aliyunModelStudio) {
      return config;
    }
    if (!autoEmotion) return config;

    final designMode =
        protocol == SpeechApiProtocol.mimoChatCompletions &&
        config.mimoTtsMode == MimoTtsMode.design;
    final basePrompt = config.voiceDesignPrompt.trim();
    // For design mode the base prompt is the voice identity; pass a short
    // hint so the analyzer does not rewrite the persona.
    final autoStyle = analyzeSpeechStyle(
      chunkText,
      speed: speed,
      baseVoiceHint: designMode
          ? null
          : (basePrompt.isEmpty ? null : basePrompt.characters.take(48).join()),
    );
    final merged = mergeSpeechStyleInstructions(
      basePrompt: basePrompt.isEmpty ? null : basePrompt,
      autoStyle: autoStyle,
      designMode: designMode,
    );
    if (merged == basePrompt) return config;
    return config.copyWith(voiceDesignPrompt: merged);
  }

  /// Loads the on-disk voice-clone sample once per chunk request.
  ///
  /// The sample path lives in [MediaApiConfig.voiceClonePath]; the raw audio
  /// is never stored in SharedPreferences.
  Future<_VoiceCloneSample?> _loadVoiceCloneSample(
    MediaApiConfig config,
  ) async {
    if (config.effectiveSpeechProtocol !=
        SpeechApiProtocol.mimoChatCompletions) {
      return null;
    }
    if (config.mimoTtsMode != MimoTtsMode.clone) return null;
    if (config.voice.trim().startsWith('data:')) return null;

    final path = config.voiceClonePath.trim();
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('用户音色样本文件已丢失，请在设置中重新上传 mp3/wav。');
    }
    final bytes = Uint8List.fromList(await file.readAsBytes());
    final lower = path.toLowerCase();
    final mime = lower.endsWith('.mp3') || lower.endsWith('.mpeg')
        ? 'audio/mpeg'
        : 'audio/wav';
    return _VoiceCloneSample(bytes: bytes, mimeType: mime);
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
      // Pause, not stop: just_audio's stop() tears the native platform down
      // (and WinRT reports each finished sentence as idle, which just_audio
      // 0.10.x also turns into a teardown). Pausing keeps the player warm so
      // the next speak() replaces the source instead of racing a re-create.
      await _audioPlayer?.pause();
    } catch (_) {
      // Stopping an already-complete player is safe.
    }

    _activeAudioFile = null;
    // Drop the playing file and any prefetched look-ahead files.
    final owned = List<File>.of(_ownedAudioFiles);
    _ownedAudioFiles.clear();
    for (final file in owned) {
      await _deleteAudioFile(file);
    }
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

class _PreparedChunk {
  const _PreparedChunk({required this.index, required this.file});

  final int index;
  final File file;
}

class _VoiceCloneSample {
  const _VoiceCloneSample({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
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
