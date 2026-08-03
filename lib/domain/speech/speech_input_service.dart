import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

enum SpeechInputAvailability { ready, permissionDenied, unavailable }

enum SpeechInputStatus { listening, stopped }

class SpeechInputResult {
  const SpeechInputResult({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

class SpeechInputFailure {
  const SpeechInputFailure({
    required this.code,
    required this.permanent,
    this.userFacingMessage,
  });

  final String code;
  final bool permanent;
  final String? userFacingMessage;

  String get userMessage {
    final explicit = userFacingMessage?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final normalized = code.toLowerCase();
    if (normalized.contains('permission') ||
        normalized.contains('not_allowed')) {
      return '未获得麦克风或语音识别权限，请在系统设置中允许后重试。';
    }
    if (normalized.contains('network')) {
      return '语音识别网络不可用，请检查网络后重试。';
    }
    if (normalized.contains('busy') || normalized.contains('already')) {
      return '系统语音识别正忙，请稍后再试。';
    }
    if (normalized.contains('language') ||
        normalized.contains('not_supported') ||
        normalized.contains('recognizer_disabled') ||
        normalized.contains('language_unavailable')) {
      return defaultTargetPlatform == TargetPlatform.windows
          ? '当前 Windows 语音识别语言不可用。请在系统设置 → 时间和语言 → 语音 中安装中文语音包，并设为默认识别语言。'
          : '当前设备暂不支持中文系统语音识别。';
    }
    if (normalized.contains('no_match') ||
        normalized.contains('speech_timeout') ||
        normalized.contains('no_speech')) {
      return '没有听清，请靠近麦克风再说一次。';
    }
    if (normalized.contains('audio') || normalized.contains('microphone')) {
      return '无法使用麦克风，请检查系统麦克风是否可用、是否被其他应用占用。';
    }
    if (normalized.contains('start_failed') ||
        normalized.contains('listen_failed')) {
      return defaultTargetPlatform == TargetPlatform.windows
          ? '未能启动语音识别。请确认已安装中文语音包，并允许应用使用麦克风。'
          : '未能启动系统语音识别，请稍后再试。';
    }
    return '语音识别失败，请稍后再试。';
  }
}

typedef SpeechInputResultCallback = void Function(SpeechInputResult result);
typedef SpeechInputStatusCallback = void Function(SpeechInputStatus status);
typedef SpeechInputErrorCallback = void Function(SpeechInputFailure failure);

abstract class SpeechInputService {
  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  });

  Future<bool> start({
    required SpeechInputResultCallback onResult,
    String preferredLanguageCode = 'zh',
  });

  Future<void> cancel();

  /// Removes page callbacks while keeping the platform recognizer reusable.
  void detach();
}

class SystemSpeechInputService implements SpeechInputService {
  SystemSpeechInputService({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;

  /// How long [start] waits for the platform "listening" status after listen().
  /// Status is delivered asynchronously on Windows (UI-thread dispatch).
  @visibleForTesting
  static Duration listeningReadyTimeout = const Duration(milliseconds: 1500);

  /// Maximum time to wait for the platform to report that a cancelled session
  /// has stopped. Some platforms deliver that status asynchronously; the
  /// timeout keeps a broken recognizer from blocking a new session forever.
  @visibleForTesting
  static Duration platformStopTimeout = const Duration(milliseconds: 500);

  SpeechInputResultCallback? _resultCallback;
  SpeechInputStatusCallback? _statusCallback;
  SpeechInputErrorCallback? _errorCallback;
  Completer<bool>? _listeningReady;
  Completer<void>? _platformStopped;
  var _initialized = false;
  // Platform callbacks do not carry a session id. While a new listen() call
  // is waiting for its own "listening" acknowledgement, Windows may still
  // deliver terminal callbacks queued by the session we just cancelled.
  // Quarantine those callbacks so they cannot stop the new UI session.
  var _awaitingFreshListening = false;

  @override
  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  }) async {
    _statusCallback = onStatus;
    _errorCallback = onError;
    try {
      // Always re-bind listeners: SpeechToText is a process-wide singleton and
      // only applies onError/onStatus on the first successful initialize.
      final ready = _initialized && _speech.isAvailable
          ? true
          : await _speech.initialize(
              onStatus: _handleStatus,
              onError: _handleError,
              debugLogging: kDebugMode,
            );
      _initialized = ready;
      if (ready) return SpeechInputAvailability.ready;
      final hasPermission = await _speech.hasPermission;
      return hasPermission
          ? SpeechInputAvailability.unavailable
          : SpeechInputAvailability.permissionDenied;
    } catch (_) {
      _initialized = false;
      return SpeechInputAvailability.unavailable;
    }
  }

  @override
  Future<bool> start({
    required SpeechInputResultCallback onResult,
    String preferredLanguageCode = 'zh',
  }) async {
    final hasPreviousSession =
        _speech.isListening ||
        _resultCallback != null ||
        _listeningReady != null ||
        _platformStopped != null;
    if (!_speech.isAvailable) {
      _resultCallback = null;
      _errorCallback?.call(
        const SpeechInputFailure(code: 'start_failed', permanent: false),
      );
      return false;
    }

    // A previous session may still be marked listening until its asynchronous
    // stopped status settles. Do not let that old status race with this one.
    if (hasPreviousSession) await cancel();
    _resultCallback = onResult;

    final ready = Completer<bool>();
    _listeningReady = ready;
    _awaitingFreshListening = true;

    try {
      final localeId = await _preferredLocaleId(preferredLanguageCode);
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: SpeechListenOptions(
          // The page cancels after every error so the platform recognizer and
          // the UI cannot drift into different active/inactive states.
          cancelOnError: true,
          partialResults: true,
          listenMode: ListenMode.dictation,
          autoPunctuation: true,
          // Dictation: allow brief thinking pauses without cutting the session.
          pauseFor: const Duration(seconds: 8),
          listenFor: const Duration(seconds: 90),
          localeId: localeId,
        ),
      );

      // Platform listen() resolves before the async "listening" status lands
      // (especially Windows). Do not trust isListening immediately.
      if (_speech.isListening) {
        _awaitingFreshListening = false;
        _completeListeningReady(true);
        return true;
      }

      final started = await ready.future.timeout(
        listeningReadyTimeout,
        onTimeout: () => _speech.isListening,
      );
      if (!started) {
        _awaitingFreshListening = false;
        _errorCallback?.call(
          const SpeechInputFailure(code: 'listen_failed', permanent: false),
        );
      } else {
        _awaitingFreshListening = false;
      }
      return started;
    } catch (e) {
      _awaitingFreshListening = false;
      _completeListeningReady(false);
      final code = e is ListenFailedException
          ? (e.message ?? 'listen_failed')
          : 'start_failed';
      _errorCallback?.call(SpeechInputFailure(code: code, permanent: false));
      return false;
    } finally {
      if (identical(_listeningReady, ready)) _listeningReady = null;
    }
  }

  @override
  Future<void> cancel() async {
    _awaitingFreshListening = false;
    _completeListeningReady(false);
    final shouldWaitForStopped =
        _speech.isListening ||
        _resultCallback != null ||
        _listeningReady != null ||
        _platformStopped != null;
    _resultCallback = null;

    Completer<void>? stopped;
    if (shouldWaitForStopped) {
      stopped = _platformStopped ??= Completer<void>();
    }

    try {
      await _speech.cancel();
    } catch (_) {
      // The recognizer may already have stopped or may be unavailable.
    }

    if (stopped == null) return;
    try {
      await stopped.future.timeout(platformStopTimeout);
    } on TimeoutException {
      // Some platform implementations do not emit a final stopped status.
      // The timeout is only a fallback; the recognizer has already received
      // cancel() above.
    } finally {
      if (identical(_platformStopped, stopped)) _platformStopped = null;
    }
  }

  @override
  void detach() {
    _awaitingFreshListening = false;
    _completeListeningReady(false);
    _completePlatformStopped();
    _platformStopped = null;
    _resultCallback = null;
    _statusCallback = null;
    _errorCallback = null;
  }

  void _completeListeningReady(bool value) {
    final pending = _listeningReady;
    if (pending != null && !pending.isCompleted) {
      pending.complete(value);
    }
  }

  void _completePlatformStopped() {
    final pending = _platformStopped;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  /// Prefer a Chinese locale when available; otherwise fall back to the device
  /// default. Never invent a locale the OS does not list — that is a common
  /// cause of "starts but never recognizes".
  Future<String?> _preferredLocaleId(String languageCode) async {
    final normalizedLanguage = languageCode.toLowerCase();
    try {
      final locales = await _speech.locales();
      final matching = [
        for (final locale in locales)
          if (_languageOf(locale.localeId) == normalizedLanguage) locale,
      ];

      if (normalizedLanguage == 'zh' && matching.isNotEmpty) {
        int rank(String raw) {
          final id = raw.toLowerCase().replaceAll('-', '_');
          if (id == 'zh_cn' || id.startsWith('zh_cn_')) return 0;
          if (id.contains('hans')) return 1;
          if (id == 'zh_tw' || id.startsWith('zh_tw_') || id.contains('hant')) {
            return 2;
          }
          return 3;
        }

        matching.sort((a, b) => rank(a.localeId).compareTo(rank(b.localeId)));
        return matching.first.localeId;
      }
      if (matching.isNotEmpty) return matching.first.localeId;

      final systemLocale = await _speech.systemLocale();
      return systemLocale?.localeId;
    } catch (_) {
      return null;
    }
  }

  String _languageOf(String localeId) {
    final primary = localeId.toLowerCase().split(RegExp('[-_]')).first;
    // Windows / some packs report Chinese as "cmn" (Mandarin).
    if (primary == 'cmn') return 'zh';
    return primary;
  }

  void _handleResult(SpeechRecognitionResult result) {
    final words = result.recognizedWords.trim();
    // Ignore empty partials that some platforms emit at session start.
    if (words.isEmpty && !result.finalResult) return;
    _resultCallback?.call(
      SpeechInputResult(
        text: result.recognizedWords,
        isFinal: result.finalResult,
      ),
    );
  }

  void _handleStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      // A "listening" status always belongs to the current session: the page
      // can only stop (and thus start a newer session) after start() resolved,
      // which requires this session's own "listening" to have been delivered.
      _awaitingFreshListening = false;
      _completeListeningReady(true);
      _statusCallback?.call(SpeechInputStatus.listening);
    } else if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      // Platform statuses carry no session identity, so a stopped/error event
      // delivered late (Windows dispatches status asynchronously) could belong
      // to a previously cancelled session. Completing the listening-ready
      // completer here would fail the NEW session's start() even though it is
      // actually listening. False completion is left to the session's own
      // operations: cancel(), detach() and start()'s error/timeout paths.
      _completePlatformStopped();
      if (_awaitingFreshListening) return;
      _statusCallback?.call(SpeechInputStatus.stopped);
    }
  }

  void _handleError(SpeechRecognitionError error) {
    // See _handleStatus: the error may belong to a previous session, so it
    // must not complete the current session's listening-ready completer.
    // Quarantine it until the new session confirms listening; otherwise a
    // cancelled session's late timeout would immediately cancel the new one.
    if (_awaitingFreshListening) return;
    _errorCallback?.call(
      SpeechInputFailure(code: error.errorMsg, permanent: error.permanent),
    );
  }
}

String mergeSpeechIntoDraft({
  required String before,
  required String transcript,
  required String after,
}) {
  final spoken = transcript.trim();
  if (spoken.isEmpty) return '$before$after';
  return [
    before,
    if (_speechSeparatorNeeded(before, spoken)) ' ',
    spoken,
    if (_speechSeparatorNeeded(spoken, after)) ' ',
    after,
  ].join();
}

bool _speechSeparatorNeeded(String left, String right) {
  if (left.isEmpty || right.isEmpty) return false;
  if (RegExp(r'\s$').hasMatch(left) || RegExp(r'^\s').hasMatch(right)) {
    return false;
  }
  return RegExp(r'[A-Za-z0-9]$').hasMatch(left) &&
      RegExp(r'^[A-Za-z0-9]').hasMatch(right);
}
