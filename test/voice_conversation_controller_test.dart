import 'dart:async';

import 'package:expert_chat/domain/speech/text_to_speech_service.dart';
import 'package:expert_chat/features/chat/controllers/voice_conversation_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeSpeechInputService, FakeTextToSpeechService;

class _Harness {
  _Harness() {
    controller = VoiceConversationController(
      speechInput: mic,
      textToSpeech: speaker,
      send: (text) {
        sent.add(text);
        return (reply = Completer<bool>()).future;
      },
      stopReply: () async => stopReplies++,
      readReply: () => latest,
      speechRequest: (id) => TextToSpeechRequest(
        messageId: id,
        text: '',
        apiConfig: null,
        apiKey: '',
      ),
      onNotice: notices.add,
    );
  }

  final mic = FakeSpeechInputService();
  final speaker = FakeTextToSpeechService();
  final sent = <String>[];
  final notices = <String>[];
  late final VoiceConversationController controller;
  Completer<bool>? reply;
  VoiceReply? latest;
  var stopReplies = 0;

  List<String> spoken([int stream = 0]) {
    final queue = speaker.streams[stream];
    return [for (var i = 0; i < queue.length; i++) queue[i]];
  }
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('full turn: listen, send on silence, read while streaming, listen '
      'again', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);

    await h.controller.start();
    expect(h.controller.phase, VoiceConversationPhase.listening);
    expect(h.mic.lastPauseFor, const Duration(seconds: 2));

    h.mic.emit('今天天气怎么样');
    expect(h.controller.transcript, '今天天气怎么样');
    h.mic.endSession();
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.replying);
    expect(h.sent, ['今天天气怎么样']);

    h.controller.onReplyProgress(
      const VoiceReply(messageId: 'a1', content: '今天晴。气温'),
    );
    expect(h.spoken(), ['今天晴。']);

    h.latest = const VoiceReply(messageId: 'a1', content: '今天晴。气温二十度。');
    h.reply!.complete(true);
    await settle();
    expect(h.spoken(), ['今天晴。', '气温二十度。']);
    expect(h.speaker.streams.single.isClosed, isTrue);

    h.speaker.finishStream();
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.listening);
    expect(h.mic.startCount, 2);
    expect(h.notices, isEmpty);
  });

  test('ignores progress from another message', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.mic
      ..emit('你好')
      ..endSession();
    await settle();
    h.controller
      ..onReplyProgress(const VoiceReply(messageId: 'a1', content: '一。二'))
      ..onReplyProgress(const VoiceReply(messageId: 'other', content: '别的。x'));
    expect(h.spoken(), ['一。']);
  });

  test('pauses after two silent listens instead of looping', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.mic.endSession();
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.listening);
    h.mic.fail('error_no_match');
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.paused);
    expect(h.notices.single, contains('没有听到声音'));
    expect(h.sent, isEmpty);

    await h.controller.tap();
    expect(h.controller.phase, VoiceConversationPhase.listening);
  });

  test('tapping while replying stops the reply and listens again', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.mic
      ..emit('讲个故事')
      ..endSession();
    await settle();
    h.controller.onReplyProgress(
      const VoiceReply(messageId: 'a1', content: '从前。有'),
    );

    await h.controller.tap();
    expect(h.stopReplies, 1);
    expect(h.speaker.streams.single.isCancelled, isTrue);
    expect(h.controller.phase, VoiceConversationPhase.listening);

    // The interrupted turn finishing later must not restart anything.
    h.reply!.complete(true);
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.listening);
    expect(h.speaker.streams, hasLength(1));
  });

  test('a rejected send pauses with a notice', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.mic
      ..emit('你好')
      ..endSession();
    await settle();
    h.reply!.complete(false);
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.paused);
    expect(h.notices.single, contains('没有发送出去'));
  });

  test('a failed reply pauses instead of reading an error', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.mic
      ..emit('你好')
      ..endSession();
    await settle();
    h.latest = const VoiceReply(messageId: 'a1', content: '', failed: true);
    h.reply!.complete(true);
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.paused);
    expect(h.notices.single, contains('回复失败'));
  });

  test('a recognizer error pauses with its message', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.mic.fail('error_network');
    await settle();
    expect(h.controller.phase, VoiceConversationPhase.paused);
    expect(h.notices.single, contains('网络'));
  });

  test('backgrounding pauses; exit closes the mode', () async {
    final h = _Harness();
    addTearDown(h.controller.dispose);
    await h.controller.start();
    h.controller.handleLifecycle(AppLifecycleState.inactive);
    expect(h.controller.phase, VoiceConversationPhase.listening);
    h.controller.handleLifecycle(AppLifecycleState.paused);
    expect(h.controller.phase, VoiceConversationPhase.paused);

    final cancels = h.mic.cancelCount;
    await h.controller.exit();
    expect(h.controller.phase, VoiceConversationPhase.off);
    expect(h.controller.active, isFalse);
    expect(h.mic.cancelCount, greaterThan(cancels));
  });
}
