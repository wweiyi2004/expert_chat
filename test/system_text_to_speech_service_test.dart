import 'dart:async';

import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/speech/fallback_text_to_speech_service.dart';
import 'package:expert_chat/domain/speech/system_text_to_speech_service.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeTextToSpeechService;

/// Each utterance waits until the test releases it (or stop() interrupts it).
class _Engine implements SystemSpeechEngine {
  final spoken = <String>[];
  final rates = <double>[];
  Completer<void>? current;
  Object? failNext;
  var stops = 0;

  @override
  Future<void> speak(String text, {required double rate}) {
    spoken.add(text);
    rates.add(rate);
    final error = failNext;
    failNext = null;
    if (error != null) return Future.error(error);
    return (current = Completer<void>()).future;
  }

  void release() {
    final c = current;
    current = null;
    c?.complete();
  }

  @override
  Future<void> stop() async {
    stops++;
    release();
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

TextToSpeechRequest request(String text, {MediaApiConfig? config}) =>
    TextToSpeechRequest(
      messageId: 'm',
      text: text,
      apiConfig: config,
      apiKey: config == null ? '' : 'secret',
      rate: 0.62,
    );

void main() {
  group('SystemTextToSpeechService', () {
    test('speaks sentences in order, then returns to idle', () async {
      final engine = _Engine();
      final service = SystemTextToSpeechService(engine: engine);
      addTearDown(service.dispose);

      await service.speak(request('第一句。**第二句**！'));
      await settle();
      expect(engine.spoken, ['第一句。']);
      expect(service.playback.value.phase, TextToSpeechPhase.speaking);
      engine.release();
      await settle();
      expect(engine.spoken, ['第一句。', '第二句！']);
      expect(engine.rates.toSet(), {0.62});
      engine.release();
      await settle();
      expect(service.playback.value.phase, TextToSpeechPhase.idle);
    });

    test('a stream waits for appended text and reports done', () async {
      final engine = _Engine();
      final service = SystemTextToSpeechService(engine: engine);
      addTearDown(service.dispose);

      final stream = service.startStream(request(''));
      await settle();
      expect(service.playback.value.phase, TextToSpeechPhase.loading);
      stream.append('你好。');
      await settle();
      expect(engine.spoken, ['你好。']);
      engine.release();
      await settle();
      expect(service.playback.value.phase, TextToSpeechPhase.loading);
      stream
        ..append('再见。')
        ..close();
      await settle();
      engine.release();
      expect(await stream.done, isTrue);
      expect(engine.spoken, ['你好。', '再见。']);
      expect(service.playback.value.phase, TextToSpeechPhase.idle);
    });

    test('stop interrupts the utterance and the stream is not done', () async {
      final engine = _Engine();
      final service = SystemTextToSpeechService(engine: engine);
      addTearDown(service.dispose);

      final stream = service.startStream(request('很长的一句话。'));
      await settle();
      await service.stop();
      expect(await stream.done, isFalse);
      expect(service.playback.value.phase, TextToSpeechPhase.idle);
    });

    test('engine failure surfaces a readable error', () async {
      final engine = _Engine()
        ..failNext = const SystemSpeechException('手机没有可用的系统语音引擎');
      final service = SystemTextToSpeechService(engine: engine);
      addTearDown(service.dispose);

      await service.speak(request('你好。'));
      await settle();
      expect(service.playback.value.phase, TextToSpeechPhase.error);
      expect(service.playback.value.errorMessage, contains('系统语音引擎'));
    });

    test('empty text is an error for speak', () async {
      final service = SystemTextToSpeechService(engine: _Engine());
      addTearDown(service.dispose);
      await service.speak(request('https://example.com'));
      expect(service.playback.value.phase, TextToSpeechPhase.error);
    });
  });

  group('FallbackTextToSpeechService', () {
    const config = MediaApiConfig(baseUrl: 'http://tts.test', model: 'tts-1');

    test(
      'routes by configuration and forwards only the active service',
      () async {
        final cloud = FakeTextToSpeechService();
        final system = FakeTextToSpeechService();
        final service = FallbackTextToSpeechService(
          cloud: cloud,
          system: system,
        );
        addTearDown(service.dispose);

        await service.speak(request('云端。', config: config));
        expect(cloud.requests, hasLength(1));
        expect(system.requests, isEmpty);
        expect(service.playback.value.phase, TextToSpeechPhase.speaking);
        final cloudId = service.playback.value.requestId;

        service.startStream(request('本地。'));
        await settle();
        expect(system.requests, hasLength(1));
        // Switching stopped the cloud speaker without leaking its idle state.
        expect(cloud.stopCount, 1);
        expect(service.playback.value.phase, TextToSpeechPhase.speaking);
        expect(service.playback.value.requestId, isNot(cloudId));
      },
    );

    test('stop silences both services', () async {
      final cloud = FakeTextToSpeechService();
      final system = FakeTextToSpeechService();
      final service = FallbackTextToSpeechService(cloud: cloud, system: system);
      addTearDown(service.dispose);
      await service.stop();
      expect(cloud.stopCount, 1);
      expect(system.stopCount, 1);
    });
  });
}
