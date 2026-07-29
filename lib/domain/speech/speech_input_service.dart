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
  const SpeechInputFailure({required this.code, required this.permanent});

  final String code;
  final bool permanent;

  String get userMessage {
    final normalized = code.toLowerCase();
    if (normalized.contains('permission') ||
        normalized.contains('not_allowed')) {
      return '未获得麦克风或语音识别权限，请在系统设置中允许后重试。';
    }
    if (normalized.contains('network')) {
      return '语音识别网络不可用，请检查网络后重试。';
    }
    if (normalized.contains('busy')) {
      return '系统语音识别正忙，请稍后再试。';
    }
    if (normalized.contains('language') ||
        normalized.contains('not_supported') ||
        normalized.contains('recognizer_disabled')) {
      return '当前设备暂不支持中文系统语音识别。';
    }
    if (normalized.contains('no_match') ||
        normalized.contains('speech_timeout')) {
      return '没有听清，请再试一次。';
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
  SpeechInputResultCallback? _resultCallback;
  SpeechInputStatusCallback? _statusCallback;
  SpeechInputErrorCallback? _errorCallback;

  @override
  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  }) async {
    _statusCallback = onStatus;
    _errorCallback = onError;
    try {
      final ready = await _speech.initialize(
        onStatus: _handleStatus,
        onError: _handleError,
      );
      if (ready) return SpeechInputAvailability.ready;
      final hasPermission = await _speech.hasPermission;
      return hasPermission
          ? SpeechInputAvailability.unavailable
          : SpeechInputAvailability.permissionDenied;
    } catch (_) {
      return SpeechInputAvailability.unavailable;
    }
  }

  @override
  Future<bool> start({
    required SpeechInputResultCallback onResult,
    String preferredLanguageCode = 'zh',
  }) async {
    _resultCallback = onResult;
    try {
      final localeId = await _preferredLocaleId(preferredLanguageCode);
      await _speech.listen(
        onResult: _handleResult,
        listenOptions: SpeechListenOptions(
          cancelOnError: true,
          partialResults: true,
          listenMode: ListenMode.dictation,
          autoPunctuation: true,
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 60),
          localeId: localeId,
        ),
      );
      return _speech.isListening;
    } catch (_) {
      _errorCallback?.call(
        const SpeechInputFailure(code: 'start_failed', permanent: false),
      );
      return false;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _speech.cancel();
    } catch (_) {
      // The recognizer may already have stopped or may be unavailable.
    }
  }

  @override
  void detach() {
    _resultCallback = null;
    _statusCallback = null;
    _errorCallback = null;
  }

  Future<String?> _preferredLocaleId(String languageCode) async {
    final normalizedLanguage = languageCode.toLowerCase();
    try {
      final systemLocale = await _speech.systemLocale();
      if (systemLocale != null &&
          _languageOf(systemLocale.localeId) == normalizedLanguage) {
        return systemLocale.localeId;
      }
      final locales = await _speech.locales();
      final matching = [
        for (final locale in locales)
          if (_languageOf(locale.localeId) == normalizedLanguage) locale,
      ];
      if (normalizedLanguage == 'zh') {
        for (final locale in matching) {
          final id = locale.localeId.toLowerCase().replaceAll('-', '_');
          if (id == 'zh_cn' || id.contains('hans')) return locale.localeId;
        }
      }
      if (matching.isNotEmpty) return matching.first.localeId;
      return systemLocale?.localeId;
    } catch (_) {
      return null;
    }
  }

  String _languageOf(String localeId) =>
      localeId.toLowerCase().split(RegExp('[-_]')).first;

  void _handleResult(SpeechRecognitionResult result) {
    _resultCallback?.call(
      SpeechInputResult(
        text: result.recognizedWords,
        isFinal: result.finalResult,
      ),
    );
  }

  void _handleStatus(String status) {
    if (status == SpeechToText.listeningStatus) {
      _statusCallback?.call(SpeechInputStatus.listening);
    } else if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      _statusCallback?.call(SpeechInputStatus.stopped);
    }
  }

  void _handleError(SpeechRecognitionError error) {
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
