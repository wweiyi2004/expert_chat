import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/speech/mimo_speech_input_service.dart';
import 'package:expert_chat/domain/speech/speech_input_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRecorder implements SpeechAudioRecorder {
  _FakeRecorder({this.permissionGranted = true, this.wavBytes = const [1, 2]});

  final bool permissionGranted;
  final List<int> wavBytes;

  /// When set, [stop] suspends until the gate completes, mimicking a real
  /// recorder that takes a while to finalise the WAV. The file is re-written
  /// when stop() completes, as the platform plugin does when it writes the
  /// final header after a cancel() that raced the pending stop().
  Completer<void>? stopGate;
  String? path;
  var cancelled = false;
  var disposed = false;
  var stopPending = false;

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<void> start(String path) async {
    this.path = path;
    await File(path).writeAsBytes(wavBytes, flush: true);
  }

  @override
  Future<String?> stop() async {
    final gate = stopGate;
    if (gate != null) {
      stopPending = true;
      await gate.future;
      await File(path!).writeAsBytes(wavBytes, flush: true);
    }
    return path;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test(
    'records WAV, submits it to MiMo ASR and emits a final transcript',
    () async {
      late RequestOptions captured;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'choices': [
                      {
                        'message': {'content': '识别结果'},
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
      final directory = await Directory.systemTemp.createTemp(
        'expert-chat-asr-',
      );
      final recorder = _FakeRecorder(wavBytes: const [1, 2, 3]);
      final service = MimoSpeechInputService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: dio),
        recorder: recorder,
        temporaryDirectory: () async => directory,
      );
      addTearDown(() async {
        await service.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final statuses = <SpeechInputStatus>[];
      final failures = <SpeechInputFailure>[];
      final results = <SpeechInputResult>[];
      expect(
        await service.initialize(onStatus: statuses.add, onError: failures.add),
        SpeechInputAvailability.ready,
      );
      expect(
        await service.start(
          config: const MediaApiConfig(
            baseUrl: MediaApiConfig.mimoBaseUrl,
            model: MediaApiConfig.mimoAsrModel,
          ),
          apiKey: 'secret',
          onResult: results.add,
        ),
        isTrue,
      );

      await service.finish(
        config: const MediaApiConfig(
          baseUrl: MediaApiConfig.mimoBaseUrl,
          model: MediaApiConfig.mimoAsrModel,
        ),
        apiKey: 'secret',
      );

      expect(statuses, [
        SpeechInputStatus.listening,
        SpeechInputStatus.stopped,
      ]);
      expect(failures, isEmpty);
      expect(results, hasLength(1));
      expect(results.single.text, '识别结果');
      expect(results.single.isFinal, isTrue);
      expect(
        captured.uri.toString(),
        '${MediaApiConfig.mimoBaseUrl}/chat/completions',
      );
      final body = jsonDecode(captured.data as String) as Map<String, dynamic>;
      expect(
        (((body['messages'] as List).single as Map)['content'] as List)
            .single['input_audio']['data'],
        'data:audio/wav;base64,${base64Encode(const [1, 2, 3])}',
      );
      expect(await File(recorder.path!).exists(), isFalse);
    },
  );

  test(
    'reports microphone permission denial without creating a recording',
    () async {
      final recorder = _FakeRecorder(permissionGranted: false);
      final service = MimoSpeechInputService(
        mediaProvider: OpenAiCompatibleMediaProvider(),
        recorder: recorder,
      );
      addTearDown(service.dispose);

      expect(
        await service.initialize(onStatus: (_) {}, onError: (_) {}),
        SpeechInputAvailability.permissionDenied,
      );
      expect(recorder.path, isNull);
    },
  );

  test(
    'cancel during a pending stop still cancels the recorder and deletes '
    'the file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'expert-chat-asr-',
      );
      final recorder = _FakeRecorder()..stopGate = Completer<void>();
      final service = MimoSpeechInputService(
        mediaProvider: OpenAiCompatibleMediaProvider(),
        recorder: recorder,
        temporaryDirectory: () async => directory,
      );
      addTearDown(() async {
        await service.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final statuses = <SpeechInputStatus>[];
      final failures = <SpeechInputFailure>[];
      final results = <SpeechInputResult>[];
      await service.initialize(onStatus: statuses.add, onError: failures.add);
      const config = MediaApiConfig(
        baseUrl: MediaApiConfig.mimoBaseUrl,
        model: MediaApiConfig.mimoAsrModel,
      );
      expect(
        await service.start(
          config: config,
          apiKey: 'secret',
          onResult: results.add,
        ),
        isTrue,
      );

      // finish() is now suspended inside the fake recorder's pending stop().
      final finishFuture = service.finish(config: config, apiKey: 'secret');
      expect(recorder.stopPending, isTrue);

      await service.cancel();

      // The recorder must be told to cancel even though finish() already
      // cleared the service-side recording flag.
      expect(recorder.cancelled, isTrue);

      // Let stop() complete; the "plugin" re-finalises the WAV file, which is
      // what used to leak on disk.
      recorder.stopGate!.complete();
      await finishFuture;

      expect(await File(recorder.path!).exists(), isFalse);
      expect(failures, isEmpty);
      expect(results, isEmpty);
    },
  );

  test(
    'automatically cancels a recording that exceeds the duration cap',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'expert-chat-asr-',
      );
      final recorder = _FakeRecorder();
      final service = MimoSpeechInputService(
        mediaProvider: OpenAiCompatibleMediaProvider(),
        recorder: recorder,
        temporaryDirectory: () async => directory,
        maxRecordingDuration: const Duration(milliseconds: 10),
      );
      addTearDown(() async {
        await service.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final statuses = <SpeechInputStatus>[];
      final failures = <SpeechInputFailure>[];
      final results = <SpeechInputResult>[];
      await service.initialize(onStatus: statuses.add, onError: failures.add);
      const config = MediaApiConfig(
        baseUrl: MediaApiConfig.mimoBaseUrl,
        model: MediaApiConfig.mimoAsrModel,
      );
      expect(
        await service.start(
          config: config,
          apiKey: 'secret',
          onResult: results.add,
        ),
        isTrue,
      );

      // Wait for the injected 10 ms duration timer to fire, report the error
      // and finish the auto-cancel (stopped status lands last).
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while ((failures.isEmpty ||
              !statuses.contains(SpeechInputStatus.stopped)) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(failures, hasLength(1));
      expect(failures.single.code, 'recording_timeout');
      expect(failures.single.userFacingMessage, contains('秒上限'));
      expect(recorder.cancelled, isTrue);
      expect(
        statuses,
        [SpeechInputStatus.listening, SpeechInputStatus.stopped],
      );
      expect(results, isEmpty);
      expect(await File(recorder.path!).exists(), isFalse);

      // The one-shot timer must not fire again after the auto-cancel.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(failures, hasLength(1));
      expect(
        statuses,
        [SpeechInputStatus.listening, SpeechInputStatus.stopped],
      );
    },
  );

  test(
    'rejects a recording larger than the upload cap before uploading it',
    () async {
      var transcribeRequested = false;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              transcribeRequested = true;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'choices': [
                      {
                        'message': {'content': '识别结果'},
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );
      final directory = await Directory.systemTemp.createTemp(
        'expert-chat-asr-',
      );
      final recorder = _FakeRecorder(wavBytes: const [1, 2, 3]);
      final service = MimoSpeechInputService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: dio),
        recorder: recorder,
        temporaryDirectory: () async => directory,
        maxRecordingFileBytes: 2,
      );
      addTearDown(() async {
        await service.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final statuses = <SpeechInputStatus>[];
      final failures = <SpeechInputFailure>[];
      final results = <SpeechInputResult>[];
      await service.initialize(onStatus: statuses.add, onError: failures.add);
      const config = MediaApiConfig(
        baseUrl: MediaApiConfig.mimoBaseUrl,
        model: MediaApiConfig.mimoAsrModel,
      );
      expect(
        await service.start(
          config: config,
          apiKey: 'secret',
          onResult: results.add,
        ),
        isTrue,
      );

      await service.finish(config: config, apiKey: 'secret');

      // The oversized file is rejected before it is read or uploaded.
      expect(transcribeRequested, isFalse);
      expect(results, isEmpty);
      expect(failures, hasLength(1));
      expect(failures.single.code, 'cloud_asr_failed');
      expect(failures.single.userFacingMessage, contains('MB 限制'));
      expect(
        statuses,
        [SpeechInputStatus.listening, SpeechInputStatus.stopped],
      );
      expect(await File(recorder.path!).exists(), isFalse);
    },
  );
}
