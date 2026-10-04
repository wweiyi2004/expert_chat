import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../domain/speech/sentence_streamer.dart';
import '../../../domain/speech/speech_input_service.dart';
import '../../../domain/speech/text_to_speech_service.dart';

/// Where the hands-free loop currently is.
enum VoiceConversationPhase {
  /// Voice mode is closed.
  off,

  /// Waiting for the microphone to open.
  starting,

  /// Listening; the turn is sent when the user stops talking.
  listening,

  /// The question was sent; the reply is generated and read aloud.
  replying,

  /// Stopped after an error, silence or backgrounding; a tap continues.
  paused,
}

/// The assistant message answering the current turn, as the page sees it.
@immutable
class VoiceReply {
  const VoiceReply({
    required this.messageId,
    required this.content,
    this.failed = false,
  });

  final String messageId;
  final String content;
  final bool failed;
}

/// Runs voice conversation mode: listen → send when the user stops talking →
/// read the reply aloud while it streams → listen again.
///
/// It always uses system recognition, which detects the end of speech; cloud
/// recognition records until tapped and cannot run hands-free. The page owns
/// chat state and forwards reply progress through [onReplyProgress].
class VoiceConversationController extends ChangeNotifier {
  VoiceConversationController({
    required this.speechInput,
    required this.textToSpeech,
    required this.send,
    required this.stopReply,
    required this.readReply,
    required this.speechRequest,
    required this.onNotice,
    this.endOfTurnPause = const Duration(seconds: 2),
  }) {
    textToSpeech.playback.addListener(_onPlayback);
  }

  final SpeechInputService speechInput;
  final TextToSpeechService textToSpeech;

  /// Sends one turn. Completes when the reply finished (true) or when the
  /// turn was rejected before sending (false).
  final Future<bool> Function(String text) send;

  /// Stops a reply that is still generating.
  final Future<void> Function() stopReply;

  /// Latest assistant reply of the current conversation, or null.
  final VoiceReply? Function() readReply;

  /// Read-aloud settings (voice, rate, cloud config) for one reply.
  final TextToSpeechRequest Function(String messageId) speechRequest;
  final void Function(String) onNotice;
  final Duration endOfTurnPause;

  /// Consecutive listens that heard nothing; the loop pauses after two.
  static const int maxSilentTurns = 2;

  VoiceConversationPhase _phase = VoiceConversationPhase.off;
  String _transcript = '';
  int _session = 0;
  int _silentTurns = 0;
  bool _disposed = false;
  final SentenceStreamer _streamer = SentenceStreamer();
  String? _replyId;
  TextToSpeechStream? _speech;

  VoiceConversationPhase get phase => _phase;

  bool get active => _phase != VoiceConversationPhase.off;

  /// What the recognizer heard in the current (or last) turn.
  String get transcript => _transcript;

  /// True while the reply is audible, as opposed to still being generated.
  bool get speaking =>
      _phase == VoiceConversationPhase.replying &&
      textToSpeech.playback.value.phase == TextToSpeechPhase.speaking;

  void _onPlayback() {
    if (!_disposed && _phase == VoiceConversationPhase.replying) {
      notifyListeners();
    }
  }

  void _set(VoiceConversationPhase phase, {String? transcript}) {
    if (_disposed) return;
    _phase = phase;
    if (transcript != null) _transcript = transcript;
    notifyListeners();
  }

  /// Opens voice mode and starts listening.
  Future<void> start() async {
    if (_disposed || active) return;
    _silentTurns = 0;
    await _listen();
  }

  /// The one big button: finish talking, interrupt the reply, or resume.
  Future<void> tap() async {
    switch (_phase) {
      case VoiceConversationPhase.listening:
        // Done talking early: send what was heard so far.
        final heard = _transcript.trim();
        final session = ++_session;
        await speechInput.cancel();
        if (session != _session) return;
        if (heard.isEmpty) {
          _pause(null);
        } else {
          _submit(heard);
        }
      case VoiceConversationPhase.replying:
        // Interrupt: keep the partial reply in the chat and talk again.
        ++_session;
        await Future.wait([textToSpeech.stop(), stopReply()]);
        _silentTurns = 0;
        await _listen();
      case VoiceConversationPhase.paused:
        _silentTurns = 0;
        await _listen();
      case VoiceConversationPhase.starting:
      case VoiceConversationPhase.off:
        return;
    }
  }

  /// Closes voice mode. A reply that is still generating keeps going.
  Future<void> exit() async {
    if (!active) return;
    ++_session;
    _set(VoiceConversationPhase.off, transcript: '');
    _closeSpeech();
    await Future.wait([speechInput.cancel(), textToSpeech.stop()]);
  }

  void handleLifecycle(AppLifecycleState state) {
    if (!active || _phase == VoiceConversationPhase.paused) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(speechInput.cancel());
      unawaited(textToSpeech.stop());
      _pause(null);
    }
  }

  /// The page calls this whenever the streaming reply grows.
  void onReplyProgress(VoiceReply reply) {
    if (_phase != VoiceConversationPhase.replying) return;
    final speech = _speechFor(reply.messageId);
    if (speech == null) return;
    for (final sentence in _streamer.update(reply.content)) {
      speech.append(sentence);
    }
  }

  Future<void> _listen() async {
    final session = ++_session;
    _closeSpeech();
    _set(VoiceConversationPhase.starting, transcript: '');
    await textToSpeech.stop();
    if (_disposed || session != _session) return;
    final availability = await speechInput.initialize(
      onStatus: (status) => _handleStatus(session, status),
      onError: (failure) => _handleError(session, failure),
    );
    if (_disposed || session != _session) return;
    if (availability != SpeechInputAvailability.ready) {
      _pause(
        availability == SpeechInputAvailability.permissionDenied
            ? '未获得麦克风或语音识别权限，请在系统设置中允许后重试。'
            : '当前设备没有可用的系统语音识别服务，无法使用语音对话。',
      );
      return;
    }
    _set(VoiceConversationPhase.listening);
    final started = await speechInput.start(
      onResult: (result) {
        if (_disposed || session != _session) return;
        final text = result.text.trim();
        if (text.isNotEmpty) _set(_phase, transcript: text);
      },
      pauseFor: endOfTurnPause,
    );
    if (_disposed || session != _session) return;
    if (!started) _pause('未能启动系统语音识别，请稍后再试。');
  }

  void _handleStatus(int session, SpeechInputStatus status) {
    if (_disposed || session != _session) return;
    if (status != SpeechInputStatus.stopped) return;
    if (_phase != VoiceConversationPhase.listening) return;
    _endTurn(session);
  }

  void _handleError(int session, SpeechInputFailure failure) {
    if (_disposed || session != _session) return;
    final code = failure.code.toLowerCase();
    final silence =
        code.contains('no_match') ||
        code.contains('speech_timeout') ||
        code.contains('no_speech');
    unawaited(speechInput.cancel());
    if (silence && _phase == VoiceConversationPhase.listening) {
      _endTurn(session);
    } else {
      _pause(failure.userMessage);
    }
  }

  /// Silence ended the turn: send it, listen again, or give up after
  /// [maxSilentTurns] empty listens so the mic is never left looping.
  void _endTurn(int session) {
    final heard = _transcript.trim();
    if (heard.isNotEmpty) {
      _submit(heard);
      return;
    }
    if (++_silentTurns >= maxSilentTurns) {
      _pause('没有听到声音，点击继续对话。');
      return;
    }
    unawaited(_listen());
  }

  void _submit(String text) {
    final session = ++_session;
    _silentTurns = 0;
    _replyId = null;
    _speech = null;
    _streamer.reset();
    _set(VoiceConversationPhase.replying, transcript: text);
    unawaited(
      send(text).then(
        (accepted) => _finishReply(session, accepted),
        onError: (Object _) => _finishReply(session, false),
      ),
    );
  }

  TextToSpeechStream? _speechFor(String messageId) {
    final existing = _speech;
    if (existing != null) return _replyId == messageId ? existing : null;
    _replyId = messageId;
    return _speech = textToSpeech.startStream(speechRequest(messageId));
  }

  Future<void> _finishReply(int session, bool accepted) async {
    if (_disposed || session != _session) return;
    if (!accepted) {
      _closeSpeech();
      _pause('这句话没有发送出去，已放回输入框。点击继续对话。');
      return;
    }
    final reply = readReply();
    if (reply == null || reply.failed) {
      _closeSpeech();
      await textToSpeech.stop();
      if (session != _session) return;
      _pause('回复失败，点击继续对话。');
      return;
    }
    final speech = _speechFor(reply.messageId);
    if (speech == null) {
      _pause(null);
      return;
    }
    for (final sentence in _streamer.finish(reply.content)) {
      speech.append(sentence);
    }
    speech.close();
    final spoken = await speech.done;
    if (_disposed || session != _session) return;
    if (spoken) {
      await _listen();
    } else {
      _pause(null);
    }
  }

  void _closeSpeech() {
    _speech?.close();
    _speech = null;
    _replyId = null;
  }

  void _pause(String? notice) {
    ++_session;
    _closeSpeech();
    _set(VoiceConversationPhase.paused);
    if (notice != null && !_disposed) onNotice(notice);
  }

  @override
  void dispose() {
    if (_disposed) return;
    ++_session;
    _disposed = true;
    textToSpeech.playback.removeListener(_onPlayback);
    _closeSpeech();
    if (_phase != VoiceConversationPhase.off) {
      unawaited(speechInput.cancel());
      unawaited(textToSpeech.stop());
    }
    super.dispose();
  }
}
