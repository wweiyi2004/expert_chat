import 'package:expert_chat/domain/speech/speech_input_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Fake recognizer that mirrors the Windows platform behavior: [listen]
/// succeeds without flipping [isListening] and status events are delivered
/// later via [deliverStatus], the way the Windows recognizer reports state
/// asynchronously on the UI thread.
class _FakeSpeechToText extends SpeechToText {
  _FakeSpeechToText() : super.withMethodChannel();

  bool _listening = false;
  int listenCalls = 0;
  int cancelCalls = 0;
  SpeechStatusListener? _statusHandler;
  SpeechErrorListener? _errorHandler;

  @override
  bool get isListening => _listening;

  @override
  bool get isAvailable => true;

  @override
  Future<bool> get hasPermission async => true;

  @override
  Future<bool> initialize({
    SpeechErrorListener? onError,
    SpeechStatusListener? onStatus,
    // Keep untyped (dynamic) to match the overridden method's signature.
    debugLogging = false,
    Duration finalTimeout = const Duration(milliseconds: 2000),
    List<SpeechConfigOption>? options,
  }) async {
    _statusHandler = onStatus;
    _errorHandler = onError;
    return true;
  }

  @override
  Future listen({
    SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    SpeechSoundLevelChange? onSoundLevelChange,
    // Keep these untyped (dynamic) to match the overridden method's signature.
    cancelOnError = false,
    partialResults = true,
    onDevice = false,
    ListenMode listenMode = ListenMode.confirmation,
    sampleRate = 0,
    SpeechListenOptions? listenOptions,
  }) async {
    listenCalls++;
    // Do not set isListening here: the platform delivers "listening" later.
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    _listening = false;
  }

  @override
  Future<List<LocaleName>> locales() async =>
      [LocaleName('zh_CN', 'Chinese')];

  @override
  Future<LocaleName?> systemLocale() async => null;

  /// Delivers a platform status event, simulating an event that the Windows
  /// recognizer dispatches asynchronously.
  void deliverStatus(String status) {
    _listening = status == SpeechToText.listeningStatus;
    _statusHandler?.call(status);
  }

  void deliverError(String code, {bool permanent = false}) {
    _errorHandler?.call(SpeechRecognitionError(code, permanent));
  }
}

void main() {
  group('mergeSpeechIntoDraft', () {
    test(
      'inserts Chinese transcript at the cursor without artificial spaces',
      () {
        expect(
          mergeSpeechIntoDraft(before: '请帮我', transcript: '写一封邮件', after: '谢谢'),
          '请帮我写一封邮件谢谢',
        );
      },
    );

    test('keeps English words separated', () {
      expect(
        mergeSpeechIntoDraft(
          before: 'Please',
          transcript: 'write an email',
          after: 'today',
        ),
        'Please write an email today',
      );
    });

    test('does not duplicate existing whitespace', () {
      expect(
        mergeSpeechIntoDraft(before: '开头 ', transcript: '中间', after: '\n结尾'),
        '开头 中间\n结尾',
      );
    });

    test('ignores blank transcript', () {
      expect(
        mergeSpeechIntoDraft(before: '已有', transcript: '  ', after: '内容'),
        '已有内容',
      );
    });
  });

  test('speech errors have actionable Chinese messages', () {
    expect(
      const SpeechInputFailure(
        code: 'error_permission',
        permanent: true,
      ).userMessage,
      contains('系统设置'),
    );
    expect(
      const SpeechInputFailure(
        code: 'error_network_timeout',
        permanent: false,
      ).userMessage,
      contains('网络'),
    );
    expect(
      const SpeechInputFailure(
        code: 'error_no_match',
        permanent: false,
      ).userMessage,
      contains('没有听清'),
    );
    expect(
      const SpeechInputFailure(
        code: 'error_speech_timeout',
        permanent: false,
      ).userMessage,
      contains('没有听清'),
    );
    expect(
      const SpeechInputFailure(
        code: 'listen_failed',
        permanent: false,
      ).userMessage,
      isNotEmpty,
    );
    expect(
      const SpeechInputFailure(
        code: 'error_audio',
        permanent: false,
      ).userMessage,
      contains('麦克风'),
    );
  });

  test('Windows language errors point at speech language packs', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(
      const SpeechInputFailure(
        code: 'error_language_unavailable',
        permanent: true,
      ).userMessage,
      contains('中文语音包'),
    );
    expect(
      const SpeechInputFailure(
        code: 'listen_failed',
        permanent: false,
      ).userMessage,
      contains('中文语音包'),
    );
  });

  group('SystemSpeechInputService stale platform events', () {
    void useFastCancel() {
      SystemSpeechInputService.platformStopTimeout = Duration.zero;
    }

    void useLongListeningReadyWait() {
      SystemSpeechInputService.listeningReadyTimeout =
          const Duration(seconds: 30);
    }

    tearDown(() {
      SystemSpeechInputService.platformStopTimeout =
          const Duration(milliseconds: 500);
      SystemSpeechInputService.listeningReadyTimeout =
          const Duration(milliseconds: 1500);
    });

    /// Lets a pending [start] call reach the point where it awaits the
    /// platform's status, the way events arrive only after listen() has
    /// completed in the real (Windows) flow.
    Future<void> settleStart() => Future<void>.delayed(Duration.zero);

    test('a late done from a cancelled session does not fail the next session',
        () async {
      // Windows dispatches status asynchronously: the stopped status of the
      // cancelled session can land while the next session is still waiting
      // for its own "listening" status.
      useFastCancel();
      useLongListeningReadyWait();

      final speech = _FakeSpeechToText();
      final service = SystemSpeechInputService(speech: speech);
      final statuses = <SpeechInputStatus>[];
      final errors = <SpeechInputFailure>[];
      await service.initialize(onStatus: statuses.add, onError: errors.add);

      // Session A starts and confirms listening.
      final sessionA = service.start(onResult: (_) {});
      await settleStart();
      speech.deliverStatus(SpeechToText.listeningStatus);
      expect(await sessionA, isTrue);

      // The user stops A; the platform has not acknowledged the stop yet.
      await service.cancel();

      // Session B starts immediately; its own "listening" has not arrived.
      final sessionB = service.start(onResult: (_) {});
      await settleStart();
      // A's late "done" lands while B is still awaiting its own status.
      speech.deliverStatus(SpeechToText.doneStatus);
      // B's own status arrives next.
      speech.deliverStatus(SpeechToText.listeningStatus);

      expect(
        await sessionB,
        isTrue,
        reason: 'A late done from the cancelled session must not fail B',
      );
      expect(
        errors.where((e) => e.code == 'listen_failed'),
        isEmpty,
        reason: 'B is actually listening; no listen_failed may be reported',
      );
      expect(statuses, [
        SpeechInputStatus.listening, // A confirmed listening
        // A's late stopped status is quarantined while B starts.
        SpeechInputStatus.listening, // B confirmed listening
      ]);
    });

    test('a late error from a cancelled session does not fail the next session',
        () async {
      useFastCancel();
      useLongListeningReadyWait();

      final speech = _FakeSpeechToText();
      final service = SystemSpeechInputService(speech: speech);
      final errors = <SpeechInputFailure>[];
      await service.initialize(onStatus: (_) {}, onError: errors.add);

      final sessionA = service.start(onResult: (_) {});
      await settleStart();
      speech.deliverStatus(SpeechToText.listeningStatus);
      expect(await sessionA, isTrue);

      await service.cancel();

      final sessionB = service.start(onResult: (_) {});
      await settleStart();
      // A's late error arrives while B is still awaiting its own status.
      speech.deliverError('error_speech_timeout');
      speech.deliverStatus(SpeechToText.listeningStatus);

      expect(
        await sessionB,
        isTrue,
        reason: 'A late error from the cancelled session must not fail B',
      );
      expect(
        errors.where((e) => e.code == 'listen_failed'),
        isEmpty,
        reason: 'B is actually listening; no listen_failed may be reported',
      );
      expect(
        errors,
        isEmpty,
        reason: 'A late platform error must not reach B\'s UI callback',
      );
    });

    test('the current session done status still releases cancel()', () async {
      // The stopped status of the current session must unblock cancel()'s
      // platform-stop wait (its 30s timeout fallback must not be what does).
      SystemSpeechInputService.platformStopTimeout =
          const Duration(seconds: 30);
      useLongListeningReadyWait();

      final speech = _FakeSpeechToText();
      final service = SystemSpeechInputService(speech: speech);
      await service.initialize(onStatus: (_) {}, onError: (_) {});

      final session = service.start(onResult: (_) {});
      await settleStart();
      speech.deliverStatus(SpeechToText.listeningStatus);
      expect(await session, isTrue);

      final cancelling = service.cancel();
      speech.deliverStatus(SpeechToText.doneStatus);
      await cancelling.timeout(const Duration(seconds: 1));
    });

    test('a session that never confirms listening still fails via the timeout',
        () async {
      useFastCancel();
      SystemSpeechInputService.listeningReadyTimeout =
          const Duration(milliseconds: 100);

      final speech = _FakeSpeechToText();
      final service = SystemSpeechInputService(speech: speech);
      final errors = <SpeechInputFailure>[];
      await service.initialize(onStatus: (_) {}, onError: errors.add);

      final session = service.start(onResult: (_) {});
      // No "listening" status ever arrives; the timeout must report failure.
      expect(await session, isFalse);
      expect(errors.map((e) => e.code), contains('listen_failed'));
    });

    test('listening status completes start() on the happy path', () async {
      useFastCancel();
      useLongListeningReadyWait();

      final speech = _FakeSpeechToText();
      final service = SystemSpeechInputService(speech: speech);
      final statuses = <SpeechInputStatus>[];
      await service.initialize(onStatus: statuses.add, onError: (_) {});

      final session = service.start(onResult: (_) {});
      await settleStart();
      speech.deliverStatus(SpeechToText.listeningStatus);

      expect(await session, isTrue);
      expect(statuses, [SpeechInputStatus.listening]);
    });
  });
}
