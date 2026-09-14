import 'dart:async';

import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/speech/speech_input_service.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service.dart';
import 'package:expert_chat/features/chat/controllers/chat_speech_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart'
    show
        FakeSpeechInputService,
        FakeMimoSpeechInputService,
        FakeTextToSpeechService;

class _System extends FakeSpeechInputService {
  final results = <SpeechInputResultCallback>[];
  final errors = <SpeechInputErrorCallback>[];
  final statuses = <SpeechInputStatusCallback>[];
  Future<SpeechInputAvailability>? initialization;
  Future<bool>? starting;
  Future<void>? cancelling;
  bool throwOnStart = false;
  int startEntered = 0;
  int cancelEntered = 0;
  int detached = 0;

  @override
  Future<SpeechInputAvailability> initialize({
    required SpeechInputStatusCallback onStatus,
    required SpeechInputErrorCallback onError,
  }) async {
    errors.add(onError);
    statuses.add(onStatus);
    final available = await super.initialize(
      onStatus: onStatus,
      onError: onError,
    );
    return initialization == null ? available : await initialization!;
  }

  @override
  Future<bool> start({
    required SpeechInputResultCallback onResult,
    String preferredLanguageCode = 'zh',
  }) async {
    startEntered++;
    results.add(onResult);
    if (throwOnStart) throw StateError('broken platform');
    if (starting != null && !await starting!) return false;
    return super.start(
      onResult: onResult,
      preferredLanguageCode: preferredLanguageCode,
    );
  }

  @override
  Future<void> cancel() async {
    cancelEntered++;
    await cancelling;
    await super.cancel();
  }

  @override
  void detach() {
    detached++;
    super.detach();
  }
}

class _Speaker extends FakeTextToSpeechService {
  Future<void>? stopping;
  void emit(TextToSpeechPlayback value) =>
      (playback as ValueNotifier<TextToSpeechPlayback>).value = value;
  @override
  Future<void> stop() async {
    await stopping;
    await super.stop();
  }
}

const _cloud = CloudSpeechConfig(
  config: MediaApiConfig(baseUrl: 'https://speech.example', model: 'asr'),
  apiKey: 'test',
);
TextToSpeechRequest _request(String id) => TextToSpeechRequest(
  messageId: id,
  text: '朗读 $id',
  apiConfig: null,
  apiKey: '',
  rate: 0.7,
  autoEmotion: false,
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _System system;
  late _Speaker speaker;
  late FakeMimoSpeechInputService cloud;
  late TextEditingController input;
  late ChatSpeechController controller;
  late List<String> notices;
  CloudSpeechConfig? config;
  setUp(() {
    system = _System();
    speaker = _Speaker();
    cloud = FakeMimoSpeechInputService();
    input = TextEditingController();
    notices = [];
    config = null;
    controller = ChatSpeechController(
      input: input,
      systemSpeechInput: system,
      textToSpeech: speaker,
      getMimoService: () => cloud,
      getCloudConfig: () => config,
      onNotice: notices.add,
    );
  });
  tearDown(() async {
    controller.dispose();
    // Flush cleanup microtasks without creating a timer in widget-test time.
    for (var i = 0; i < 10; i++) {
      await Future<void>.value();
    }
    input.dispose();
    await speaker.dispose();
  });

  test(
    'system partials replace selected text and phrase finals keep listening',
    () async {
      input.value = const TextEditingValue(
        text: 'hello old world',
        selection: TextSelection(baseOffset: 6, extentOffset: 9),
      );
      await controller.toggleSpeech();
      system.emit('new');
      expect(input.text, 'hello new world');
      system.emit('new phrase', isFinal: true);
      expect(input.text, 'hello new phrase world');
      expect(controller.listening, isTrue);
      expect(speaker.requests, isEmpty);
    },
  );

  test(
    'cancel invalidates old results, status and errors after restart',
    () async {
      await controller.toggleSpeech();
      final oldResult = system.results.single;
      final oldError = system.errors.single;
      final oldStatus = system.statuses.single;
      await controller.cancelSpeech();
      await controller.toggleSpeech();
      oldResult(const SpeechInputResult(text: 'stale', isFinal: true));
      oldError(const SpeechInputFailure(code: 'network', permanent: false));
      oldStatus(SpeechInputStatus.stopped);
      expect(input.text, isEmpty);
      expect(controller.listening, isTrue);
      expect(notices, isEmpty);
      system.emit('fresh');
      expect(input.text, 'fresh');
    },
  );

  test(
    'error stops the recognizer and rejects later results from that session',
    () async {
      await controller.toggleSpeech();
      system.fail('network');
      system.emit('late');
      await _settle();
      expect(controller.listening, isFalse);
      expect(controller.busy, isFalse);
      expect(system.cancelCount, 1);
      expect(input.text, isEmpty);
      expect(notices.single, contains('网络'));
    },
  );

  test('timeout after recognized text is quiet but still cleans up', () async {
    await controller.toggleSpeech();
    system.emit('已识别');
    system.fail('speech_timeout');
    await _settle();
    expect(input.text, '已识别');
    expect(notices, isEmpty);
    expect(system.cancelCount, 1);
  });

  test('permission sheet inactivity keeps initialization alive', () async {
    final gate = Completer<SpeechInputAvailability>();
    system.initialization = gate.future;
    final starting = controller.toggleSpeech();
    await _settle();
    controller.handleLifecycle(AppLifecycleState.inactive);
    controller.handleLifecycle(AppLifecycleState.resumed);
    gate.complete(SpeechInputAvailability.ready);
    await starting;
    expect(system.cancelCount, 0);
    expect(controller.listening, isTrue);
  });

  test(
    'real background during initialization prevents microphone start',
    () async {
      final gate = Completer<SpeechInputAvailability>();
      system.initialization = gate.future;
      final starting = controller.toggleSpeech();
      await _settle();
      controller.handleLifecycle(AppLifecycleState.paused);
      gate.complete(SpeechInputAvailability.ready);
      await starting;
      await _settle();
      expect(system.startEntered, 0);
      expect(controller.busy, isFalse);
      expect(controller.listening, isFalse);
    },
  );

  test(
    'rapid taps while stopping playback cannot start duplicate recognition',
    () async {
      final gate = Completer<void>();
      speaker.stopping = gate.future;
      final first = controller.toggleSpeech();
      await controller.toggleSpeech();
      gate.complete();
      await first;
      expect(system.startEntered, 1);
    },
  );

  test(
    'context change while stopping playback invalidates pending recognition',
    () async {
      final gate = Completer<void>();
      speaker.stopping = gate.future;
      final starting = controller.toggleSpeech();
      await _settle();
      final stopping = controller.stopAll();
      gate.complete();
      await Future.wait([starting, stopping]);
      expect(system.initializeCount, 0);
      expect(controller.busy, isFalse);
    },
  );

  test(
    'restart waits for slow old start and cancellation before acquiring microphone',
    () async {
      final startGate = Completer<bool>();
      final cancelGate = Completer<void>();
      system.starting = startGate.future;
      system.cancelling = cancelGate.future;
      final old = controller.toggleSpeech();
      await _settle();
      expect(system.startEntered, 1);
      final cancelling = controller.cancelSpeech();
      final next = controller.toggleSpeech();
      await _settle();
      expect(system.startEntered, 1);
      startGate.complete(true);
      await _settle();
      expect(system.startEntered, 1);
      cancelGate.complete();
      await Future.wait([old, cancelling, next]);
      expect(system.startEntered, 2);
      expect(controller.listening, isTrue);
      final cancellations = system.cancelCount;
      await _settle();
      expect(system.cancelCount, cancellations);
    },
  );

  test(
    'platform start exception releases busy state and permits retry',
    () async {
      system.throwOnStart = true;
      await controller.toggleSpeech();
      expect(controller.busy, isFalse);
      expect(notices, hasLength(1));
      system.throwOnStart = false;
      await controller.toggleSpeech();
      expect(controller.listening, isTrue);
    },
  );

  test(
    'cloud final transcript inserts at the live cursor after upload edits',
    () async {
      config = _cloud;
      input.text = 'old';
      await controller.toggleSpeech();
      final finishing = controller.toggleSpeech();
      input.value = const TextEditingValue(
        text: 'new draft',
        selection: TextSelection.collapsed(offset: 3),
      );
      cloud.finishGate.complete();
      await finishing;
      expect(input.text, 'new识别结果 draft');
      expect(controller.busy, isFalse);
      expect(controller.listening, isFalse);
      await cloud.finish(config: _cloud.config, apiKey: _cloud.apiKey);
      expect(input.text, 'new识别结果 draft');
    },
  );

  test('cloud upload cancellation ignores the late transcript', () async {
    config = _cloud;
    await controller.toggleSpeech();
    final finishing = controller.toggleSpeech();
    await controller.toggleSpeech();
    input.text = 'keep';
    cloud.finishGate.complete();
    await finishing;
    expect(input.text, 'keep');
    expect(cloud.cancelCount, 1);
    expect(controller.busy, isFalse);
  });

  test(
    'cloud restart waits for cancelled upload to release service callbacks',
    () async {
      config = _cloud;
      await controller.toggleSpeech();
      final finishing = controller.toggleSpeech();
      await controller.cancelSpeech();
      final next = controller.toggleSpeech();
      await _settle();
      expect(cloud.startCount, 1);
      cloud.finishGate.complete();
      await Future.wait([finishing, next]);
      expect(cloud.startCount, 2);
      expect(input.text, isEmpty);
      expect(controller.listening, isTrue);
    },
  );

  test(
    'removed cloud configuration cancels recording without uploading',
    () async {
      config = _cloud;
      await controller.toggleSpeech();
      config = null;
      await controller.toggleSpeech();
      expect(cloud.cancelCount, 1);
      expect(controller.busy, isFalse);
      expect(notices.last, contains('配置已变更'));
    },
  );

  test(
    'playback waits for microphone cancellation and preserves request options',
    () async {
      await controller.toggleSpeech();
      final gate = Completer<void>();
      system.cancelling = gate.future;
      final request = _request('message');
      final reading = controller.togglePlayback(request);
      await _settle();
      expect(speaker.requests, isEmpty);
      gate.complete();
      await reading;
      expect(speaker.requests.single, same(request));
      expect(controller.listening, isFalse);
      await controller.togglePlayback(request);
      expect(controller.playback.isActive, isFalse);
    },
  );

  test(
    'latest playback intent wins while microphone cancellation is pending',
    () async {
      await controller.toggleSpeech();
      final gate = Completer<void>();
      system.cancelling = gate.future;
      final first = controller.togglePlayback(_request('first'));
      final next = controller.togglePlayback(_request('next'));
      await _settle();
      expect(speaker.requests, isEmpty);
      gate.complete();
      await Future.wait([first, next]);
      expect(speaker.requests.map((r) => r.messageId), ['next']);
    },
  );

  test('context change prevents delayed playback from starting', () async {
    await controller.toggleSpeech();
    final gate = Completer<void>();
    system.cancelling = gate.future;
    final reading = controller.togglePlayback(_request('old'));
    final stopping = controller.stopAll();
    gate.complete();
    await Future.wait([reading, stopping]);
    expect(speaker.requests, isEmpty);
  });

  testWidgets(
    'playback errors are shown once per request and queued notices expire on context change',
    (tester) async {
      controller.addListener(tester.binding.scheduleFrame);
      speaker.emit(
        const TextToSpeechPlayback(
          phase: TextToSpeechPhase.error,
          messageId: 'one',
          requestId: 10,
          errorMessage: 'first',
        ),
      );
      await tester.pump();
      speaker.emit(
        const TextToSpeechPlayback(
          phase: TextToSpeechPhase.error,
          messageId: 'one',
          requestId: 10,
          errorMessage: 'duplicate',
        ),
      );
      await tester.pump();
      expect(notices, ['first']);
      speaker.emit(
        const TextToSpeechPlayback(
          phase: TextToSpeechPhase.error,
          messageId: 'one',
          requestId: 11,
          errorMessage: 'stale',
        ),
      );
      await tester.runAsync(controller.stopAll);
      await tester.pump();
      expect(notices, ['first']);
    },
  );

  test(
    'dispose detaches services and discards captured late callbacks',
    () async {
      await controller.toggleSpeech();
      final result = system.results.single;
      controller.dispose();
      result(const SpeechInputResult(text: 'late', isFinal: true));
      await _settle();
      expect(system.detached, 1);
      expect(system.cancelCount, 1);
      expect(input.text, isEmpty);
    },
  );
}
