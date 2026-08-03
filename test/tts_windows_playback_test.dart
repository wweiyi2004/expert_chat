import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service_io.dart'
    as tts_io;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Points [getTemporaryDirectory] at a test-owned temp folder so the service's
/// speech files never touch the real app cache during tests.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final Directory root;

  @override
  Future<String?> getTemporaryPath() async => root.path;
}

/// A [JustAudioPlatform] that reproduces just_audio_windows 0.2.3's WinRT
/// behavior: when a sentence finishes, the native player reports
/// [ProcessingStateMessage.idle] — never `completed` — because WinRT's
/// MediaPlaybackState enum has no terminal state and falls back to None.
///
/// [completionDelay] controls how long after play() the "finished" signal is
/// emitted; [knownDuration] is the duration load() reports (null simulates a
/// NaturalDuration the native layer could not resolve).
class FakeJustAudioPlatform extends JustAudioPlatform {
  FakeJustAudioPlatform({
    this.knownDuration,
    this.completionDelay = const Duration(milliseconds: 30),
    this.reportCompletedOnLoad = false,
  });

  final Duration? knownDuration;
  final Duration completionDelay;

  /// Simulates just_audio_windows reporting completed at position 0 right
  /// after load (NaturalDuration still unresolved).
  final bool reportCompletedOnLoad;
  final List<FakeAudioPlayerPlatform> players = [];
  int _retiredPlayCalls = 0;

  /// Play calls across every player that ever existed: the service's own
  /// dispose flow removes players from [players] once a sentence ends.
  int get totalPlayCalls =>
      _retiredPlayCalls +
      players.fold(0, (sum, player) => sum + player.playCalls);

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = FakeAudioPlayerPlatform(
      request.id,
      knownDuration: knownDuration,
      completionDelay: completionDelay,
      reportCompletedOnLoad: reportCompletedOnLoad,
    );
    players.add(player);
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    final matches = players.where((p) => p.id == request.id).toList();
    for (final player in matches) {
      _retiredPlayCalls += player.playCalls;
      player.close();
    }
    players.removeWhere((p) => p.id == request.id);
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    for (final player in players) {
      player.close();
    }
    players.clear();
    return DisposeAllPlayersResponse();
  }
}

class FakeAudioPlayerPlatform extends AudioPlayerPlatform {
  FakeAudioPlayerPlatform(
    super.id, {
    required this.knownDuration,
    required this.completionDelay,
    this.reportCompletedOnLoad = false,
  });

  final Duration? knownDuration;
  final Duration completionDelay;

  /// When true, load ends in `completed` at position 0 with a zero/null
  /// duration — the just_audio_windows bug that previously skipped play().
  final bool reportCompletedOnLoad;
  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();
  final StreamController<PlayerDataMessage> _data =
      StreamController<PlayerDataMessage>.broadcast();
  Timer? _completionTimer;
  bool _closed = false;
  int playCalls = 0;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void _emit(ProcessingStateMessage state, Duration position) {
    if (_closed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: position,
        bufferedPosition: Duration.zero,
        duration: knownDuration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _emit(ProcessingStateMessage.loading, Duration.zero);
    if (reportCompletedOnLoad) {
      // Position == NaturalDuration == 0 → plugin reports completed.
      _emit(ProcessingStateMessage.completed, Duration.zero);
    } else {
      _emit(ProcessingStateMessage.ready, Duration.zero);
    }
    return LoadResponse(duration: knownDuration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    playCalls++;
    _data.add(PlayerDataMessage(playing: true));
    _emit(ProcessingStateMessage.ready, Duration.zero);
    // Windows plays but never reports completed; the finished sentence is
    // announced as idle after [completionDelay].
    _completionTimer?.cancel();
    _completionTimer = Timer(completionDelay, () {
      if (_closed) return;
      _data.add(PlayerDataMessage(playing: false));
      _emit(ProcessingStateMessage.idle, knownDuration ?? Duration.zero);
    });
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _completionTimer?.cancel();
    _data.add(PlayerDataMessage(playing: false));
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();

  void close() {
    _closed = true;
    _completionTimer?.cancel();
    _events.close();
    _data.close();
  }
}

Dio _shortAudioDio() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<List<int>>(
            requestOptions: options,
            statusCode: 200,
            data: List<int>.filled(32, 1),
          ),
        );
      },
    ),
  );

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late PathProviderPlatform previousPathProvider;
  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'expert-chat-tts-playback-',
    );
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempRoot);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });
  return runTests();
}

/// Polls [service.playback] until request [requestId] settles into idle
/// (or an error is reported), failing the test after [timeout].
Future<void> waitForSettledIdle(
  tts_io.ApiTextToSpeechService service,
  int requestId, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final playback = service.playback.value;
    if (playback.requestId == requestId) {
      if (playback.phase == TextToSpeechPhase.idle) return;
      if (playback.phase == TextToSpeechPhase.error) {
        fail('playback errored: ${playback.errorMessage}');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'request $requestId never reached idle '
    '(stayed ${service.playback.value.phase}: '
    '${service.playback.value.errorMessage})',
  );
}

Future<void> runTests() async {
  const config = MediaApiConfig(baseUrl: 'http://placeholder', model: 'tts-1');

  test(
    'Windows idle end-signal finishes an unknown-duration sentence promptly',
    () async {
      // just_audio_windows' WinRT backend never reports completed: the
      // MediaPlaybackState enum has no terminal value, so a finished sentence
      // is broadcast as idle. With an unresolvable duration the old completion
      // wait (completed event or 3-minute timeout) left the button stuck on
      // speaking long after the audio ended.
      final platform = FakeJustAudioPlatform(knownDuration: null);
      final previous = JustAudioPlatform.instance;
      JustAudioPlatform.instance = platform;
      addTearDown(() => JustAudioPlatform.instance = previous);

      final service = tts_io.ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: _shortAudioDio()),
        initialAudioPlayer: AudioPlayer(handleAudioSessionActivation: false),
      );
      addTearDown(service.dispose);

      unawaited(
        service.speak(
          const TextToSpeechRequest(
            messageId: 'assistant-1',
            text: '你好。',
            apiConfig: config,
            apiKey: 'secret',
          ),
        ),
      );

      await waitForSettledIdle(service, 1);
    },
  );

  test(
    'Windows idle end-signal lets every sentence play and finishes cleanly',
    () async {
      final platform = FakeJustAudioPlatform(
        knownDuration: const Duration(milliseconds: 3000),
      );
      final previous = JustAudioPlatform.instance;
      JustAudioPlatform.instance = platform;
      addTearDown(() => JustAudioPlatform.instance = previous);

      final service = tts_io.ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: _shortAudioDio()),
        initialAudioPlayer: AudioPlayer(handleAudioSessionActivation: false),
      );
      addTearDown(service.dispose);

      unawaited(
        service.speak(
          const TextToSpeechRequest(
            messageId: 'assistant-1',
            text: '第一句。第二句。',
            apiConfig: config,
            apiKey: 'secret',
          ),
        ),
      );

      await waitForSettledIdle(service, 1, timeout: const Duration(seconds: 10));
      expect(platform.totalPlayCalls, 2);
    },
  );

  test(
    'audio that ends before play() returns is not skipped',
    () async {
      // Ultra-short audio can finish on the native side before the play()
      // future resolves. The idle signal must still count as completion, not
      // wait out the duration-bounded fallback (duration + 500ms).
      final platform = FakeJustAudioPlatform(
        knownDuration: const Duration(milliseconds: 3000),
        completionDelay: Duration.zero,
      );
      final previous = JustAudioPlatform.instance;
      JustAudioPlatform.instance = platform;
      addTearDown(() => JustAudioPlatform.instance = previous);

      final service = tts_io.ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: _shortAudioDio()),
        initialAudioPlayer: AudioPlayer(handleAudioSessionActivation: false),
      );
      addTearDown(service.dispose);

      unawaited(
        service.speak(
          const TextToSpeechRequest(
            messageId: 'assistant-1',
            text: '你好。',
            apiConfig: config,
            apiKey: 'secret',
          ),
        ),
      );

      await waitForSettledIdle(service, 1, timeout: const Duration(seconds: 2));
    },
  );

  test(
    'false completed-at-load still plays instead of silent skip',
    () async {
      // Regression: just_audio_windows reports completed when
      // Position == NaturalDuration == 0 right after load. The old wait loop
      // treated that as "already finished" and never called play().
      final platform = FakeJustAudioPlatform(
        knownDuration: null,
        completionDelay: const Duration(milliseconds: 40),
        reportCompletedOnLoad: true,
      );
      final previous = JustAudioPlatform.instance;
      JustAudioPlatform.instance = platform;
      addTearDown(() => JustAudioPlatform.instance = previous);

      final service = tts_io.ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: _shortAudioDio()),
        initialAudioPlayer: AudioPlayer(handleAudioSessionActivation: false),
      );
      addTearDown(service.dispose);

      unawaited(
        service.speak(
          const TextToSpeechRequest(
            messageId: 'assistant-1',
            text: '你好。世界。',
            apiConfig: config,
            apiKey: 'secret',
          ),
        ),
      );

      await waitForSettledIdle(service, 1, timeout: const Duration(seconds: 5));
      expect(platform.totalPlayCalls, 2);
    },
  );
}
