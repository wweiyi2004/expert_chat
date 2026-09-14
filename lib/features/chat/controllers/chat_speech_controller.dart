import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../data/media_api_config.dart';
import '../../../domain/speech/mimo_speech_input_service.dart';
import '../../../domain/speech/speech_input_service.dart';
import '../../../domain/speech/text_to_speech_service.dart';

class CloudSpeechConfig {
  const CloudSpeechConfig({required this.config, required this.apiKey});
  final MediaApiConfig config;
  final String apiKey;
}

/// Coordinates microphone and speaker lifecycle for one chat page. Services
/// and the draft controller are borrowed; their owners handle their disposal.
class ChatSpeechController extends ChangeNotifier {
  ChatSpeechController({
    required this.input,
    required this.systemSpeechInput,
    required TextToSpeechService textToSpeech,
    required this.getMimoService,
    required this.getCloudConfig,
    required this.onNotice,
  }) : _textToSpeech = textToSpeech,
       _ttsPlayback = textToSpeech.playback.value {
    _textToSpeech.playback.addListener(_handleTextToSpeechPlayback);
  }

  final TextEditingController input;
  final SpeechInputService systemSpeechInput;
  final TextToSpeechService _textToSpeech;
  final MimoSpeechInputService Function() getMimoService;
  final CloudSpeechConfig? Function() getCloudConfig;
  final void Function(String) onNotice;
  MimoSpeechInputService? _mimoSpeechInput;
  TextToSpeechPlayback _ttsPlayback;
  bool _disposed = false;
  bool _usingMimoAsr = false;
  bool _speechBusy = false;
  bool _speechListening = false;
  bool _speechReceivedText = false;
  bool _speechFailureReported = false;
  int _speechSession = 0;
  String _speechBefore = '';
  String _speechAfter = '';
  int _shownTtsErrorRequest = -1;
  int _audioIntent = 0;
  Future<void>? _pendingStart;
  Future<void> _pendingCancel = Future.value();

  bool get busy => _speechBusy;
  bool get listening => _speechListening;
  bool get usesCloudAsr => _usingMimoAsr;
  TextToSpeechPlayback get playback => _ttsPlayback;

  void _update(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  void _notice(String message) {
    if (!_disposed) onNotice(message);
  }

  Future<void> togglePlayback(TextToSpeechRequest request) async {
    if (_disposed) return;
    if (_ttsPlayback.isFor(request.messageId) && _ttsPlayback.isActive) {
      ++_audioIntent;
      await _textToSpeech.stop();
      return;
    }
    final stopping = cancelSpeech();
    final intent = _audioIntent;
    await stopping;
    await _pendingStart;
    if (_disposed || intent != _audioIntent) return;
    await _textToSpeech.speak(request);
  }

  Future<void> stopAll() async {
    final microphone = cancelSpeech();
    final speaker = _textToSpeech.stop();
    await Future.wait([microphone, speaker]);
  }

  void handleLifecycle(AppLifecycleState state) {
    // A permission sheet can temporarily make the app inactive.
    if (state == AppLifecycleState.inactive && busy && !listening) return;
    if (state != AppLifecycleState.resumed) unawaited(stopAll());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_speechSession;
    ++_audioIntent;
    systemSpeechInput.detach();
    _mimoSpeechInput?.detach();
    unawaited(_cancelSpeechInput(false));
    if (_mimoSpeechInput != null) unawaited(_cancelSpeechInput(true));
    _textToSpeech.playback.removeListener(_handleTextToSpeechPlayback);
    unawaited(_textToSpeech.stop());
    super.dispose();
  }

  void _handleTextToSpeechPlayback() {
    if (_disposed) return;
    final next = _textToSpeech.playback.value;
    final error = next.errorMessage;
    final showError = error != null && _shownTtsErrorRequest != next.requestId;
    if (showError) _shownTtsErrorRequest = next.requestId;

    _update(() => _ttsPlayback = next);
    if (!showError) return;
    final intent = _audioIntent;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && intent == _audioIntent) _notice(error);
    });
  }

  Future<void> toggleSpeech() async {
    if (_disposed) return;
    if (_speechBusy) {
      // A second tap during MiMo upload is an explicit cancellation request.
      if (_usingMimoAsr) await cancelSpeech();
      return;
    }
    if (_speechListening) {
      if (_usingMimoAsr) {
        await _finishMimoSpeech();
      } else {
        await cancelSpeech();
      }
      return;
    }

    final settings = getCloudConfig();
    final useMimoAsr = settings != null;
    final session = ++_speechSession;
    ++_audioIntent;
    _speechFailureReported = false;
    _usingMimoAsr = useMimoAsr;
    _update(() => _speechBusy = true);
    final previous = _pendingStart;
    final operation = _startSpeech(session, settings, previous);
    _pendingStart = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingStart, operation)) _pendingStart = null;
    }
  }

  Future<void> _startSpeech(
    int session,
    CloudSpeechConfig? settings,
    Future<void>? previous,
  ) async {
    final useMimoAsr = settings != null;
    try {
      await previous;
      await _pendingCancel;
      if (_disposed || session != _speechSession) return;
      await _textToSpeech.stop();
      if (_disposed || session != _speechSession) return;
      final availability = useMimoAsr
          ? await _mimoService.initialize(
              onStatus: (status) => _handleSpeechStatus(session, status),
              onError: (failure) => _handleSpeechError(session, failure),
            )
          : await systemSpeechInput.initialize(
              onStatus: (status) => _handleSpeechStatus(session, status),
              onError: (failure) => _handleSpeechError(session, failure),
            );
      if (_disposed || session != _speechSession) return;

      if (availability != SpeechInputAvailability.ready) {
        _update(() => _speechBusy = false);
        _notice(
          availability == SpeechInputAvailability.permissionDenied
              ? '未获得麦克风或语音识别权限，请在系统设置中允许后重试。'
              : useMimoAsr
              ? '当前设备无法录制音频，请检查麦克风是否可用。'
              : '当前设备没有可用的系统语音识别服务。',
        );
        return;
      }

      final text = input.text;
      final selection = input.selection;
      final selectionValid =
          selection.isValid &&
          selection.start >= 0 &&
          selection.end <= text.length;
      final start = selectionValid ? selection.start : text.length;
      final end = selectionValid ? selection.end : text.length;
      _speechBefore = text.substring(0, start);
      _speechAfter = text.substring(end);
      _speechReceivedText = false;

      final started = useMimoAsr
          ? await _mimoService.start(
              config: settings.config,
              apiKey: settings.apiKey,
              onResult: (result) => _handleSpeechResult(session, result),
            )
          : await systemSpeechInput.start(
              onResult: (result) => _handleSpeechResult(session, result),
            );
      if (_disposed || session != _speechSession) {
        if (started) await _cancelSpeechInput(useMimoAsr);
        return;
      }
      _update(() {
        _speechBusy = false;
        _speechListening = started;
      });
      if (!started) {
        // Ensure no orphan microphone session if status never flipped active.
        await _cancelSpeechInput(useMimoAsr);
        if (_disposed || session != _speechSession) return;
        if (!_speechFailureReported) {
          _notice(
            useMimoAsr
                ? '未能启动录音，请检查麦克风权限后重试。'
                : defaultTargetPlatform == TargetPlatform.windows
                ? '未能启动语音识别。请检查麦克风权限，并在系统设置中安装中文语音包。'
                : '未能启动系统语音识别，请稍后再试。',
          );
        }
      } else if (useMimoAsr && !_disposed) {
        // Cloud ASR has no partials; make the second-tap finish step obvious.
        _notice('已开始录音。说完后再次点击麦克风即可识别。');
      }
    } catch (_) {
      if (!_disposed && session == _speechSession) {
        _handleSpeechError(
          session,
          const SpeechInputFailure(code: 'start_failed', permanent: false),
        );
      }
    }
  }

  MimoSpeechInputService get _mimoService {
    final existing = _mimoSpeechInput;
    if (existing != null) return existing;
    final created = getMimoService();
    _mimoSpeechInput = created;
    return created;
  }

  Future<void> _finishMimoSpeech() async {
    final operation = _uploadMimoSpeech();
    _pendingStart = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingStart, operation)) _pendingStart = null;
    }
  }

  Future<void> _uploadMimoSpeech() async {
    if (!_speechListening || !_usingMimoAsr) return;
    final settings = getCloudConfig();
    if (settings == null) {
      final stopping = cancelSpeech();
      final intent = _audioIntent;
      await stopping;
      if (intent == _audioIntent) {
        _notice('MiMo 云端语音识别配置已变更，请重新开始录音。');
      }
      return;
    }
    final session = _speechSession;
    _update(() {
      _speechListening = false;
      _speechBusy = true;
    });
    try {
      await _mimoService.finish(
        config: settings.config,
        apiKey: settings.apiKey,
      );
    } catch (_) {
      _handleSpeechError(
        session,
        const SpeechInputFailure(code: 'cloud_asr_failed', permanent: false),
      );
    }
    if (_disposed || session != _speechSession) return;
    // The service normally sends a final result or a stopped status. This
    // fallback prevents a broken recorder implementation from leaving the
    // composer in a perpetual loading state.
    if (_speechBusy) _update(() => _speechBusy = false);
  }

  void _handleSpeechResult(int session, SpeechInputResult result) {
    if (_disposed || session != _speechSession) return;
    final spoken = result.text.trim();
    if (spoken.isNotEmpty) {
      _speechReceivedText = true;
      if (_usingMimoAsr) {
        // The composer stays editable while the MiMo upload is in flight, so
        // the snapshot taken at recording start may be stale. Insert at the
        // live cursor position instead of rebuilding from the old snapshot,
        // which would discard anything typed during the upload.
        final current = input.value;
        final text = current.text;
        final selection = current.selection;
        final valid =
            selection.isValid &&
            selection.start >= 0 &&
            selection.end <= text.length;
        final start = valid ? selection.start : text.length;
        final end = valid ? selection.end : start;
        final before = text.substring(0, start);
        final after = text.substring(end);
        input.value = TextEditingValue(
          text: mergeSpeechIntoDraft(
            before: before,
            transcript: spoken,
            after: after,
          ),
          selection: TextSelection.collapsed(
            offset: mergeSpeechIntoDraft(
              before: before,
              transcript: spoken,
              after: '',
            ).length,
          ),
        );
      } else {
        final merged = mergeSpeechIntoDraft(
          before: _speechBefore,
          transcript: spoken,
          after: _speechAfter,
        );
        input.value = TextEditingValue(
          text: merged,
          selection: TextSelection.collapsed(
            offset: mergeSpeechIntoDraft(
              before: _speechBefore,
              transcript: spoken,
              after: '',
            ).length,
          ),
        );
      }
    }
    // Cloud ASR emits a single final transcript after upload — that ends the
    // session. System dictation emits one finalResult per phrase while the
    // platform session is still open (pauseFor/listenFor); treating those as
    // session-end hid the listening indicator and left the mic orphaned.
    if (result.isFinal && _usingMimoAsr && (_speechListening || _speechBusy)) {
      ++_speechSession;
      _update(() {
        _speechListening = false;
        _speechBusy = false;
      });
    }
  }

  void _handleSpeechStatus(int session, SpeechInputStatus status) {
    if (_disposed || session != _speechSession) return;
    final listening = status == SpeechInputStatus.listening;
    if (_speechListening == listening && !_speechBusy) return;
    _update(() {
      _speechListening = listening;
      _speechBusy = false;
    });
  }

  void _handleSpeechError(int session, SpeechInputFailure failure) {
    if (_disposed || session != _speechSession) return;
    _speechFailureReported = true;
    final code = failure.code.toLowerCase();
    final wasActive = _speechListening || _speechBusy;
    final quietTimeout =
        _speechReceivedText &&
        (code.contains('no_match') || code.contains('speech_timeout'));
    if (wasActive) {
      _update(() {
        _speechListening = false;
        _speechBusy = false;
      });
    }
    // Some platforms keep the recognizer alive after a non-permanent error.
    // Always terminate it here so a hidden microphone cannot outlive the UI.
    if (wasActive) {
      ++_speechSession;
      unawaited(_cancelSpeechInput(_usingMimoAsr));
    }
    if (!quietTimeout) _notice(failure.userMessage);
  }

  Future<void> cancelSpeech() async {
    final wasActive = _speechListening || _speechBusy;
    final useMimoAsr = _usingMimoAsr;
    ++_speechSession;
    ++_audioIntent;
    if (!_disposed && wasActive) {
      _update(() {
        _speechListening = false;
        _speechBusy = false;
      });
    }
    if (wasActive) {
      await _cancelSpeechInput(useMimoAsr);
    } else {
      await _pendingCancel;
    }
  }

  Future<void> _cancelSpeechInput(bool useMimoAsr) {
    final operation = _pendingCancel.then((_) async {
      if (useMimoAsr) {
        await _mimoSpeechInput?.cancel();
      } else {
        await systemSpeechInput.cancel();
      }
    });
    _pendingCancel = operation.catchError((Object _) {});
    return _pendingCancel;
  }
}
