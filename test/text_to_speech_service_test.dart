import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:dio/dio.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service.dart';
import 'package:expert_chat/domain/speech/text_to_speech_service_stub.dart'
    as web_tts;
import 'package:flutter_test/flutter_test.dart';

Future<void> waitForPhase(
  ApiTextToSpeechService service,
  TextToSpeechPhase phase,
) async {
  for (var i = 0; i < 200; i++) {
    if (service.playback.value.phase == phase) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(
    'playback never reached $phase '
    '(stayed ${service.playback.value.phase}: ${service.playback.value.errorMessage})',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('prepareTextForSpeech', () {
    test('keeps prose while removing markdown, URLs and citations', () {
      const source = '''
# 标题
这是 **重点**，请看[文档](https://example.com/guide) [1]。

```dart
print('不该朗读的代码');
```

- 第二项：<https://example.com/more>
''';

      final text = prepareTextForSpeech(source);

      expect(text, contains('标题'));
      expect(text, contains('这是 重点，请看文档'));
      expect(text, contains('代码内容已省略'));
      expect(text, contains('第二项'));
      expect(text, isNot(contains('https://')));
      expect(text, isNot(contains('```')));
      expect(text, isNot(contains('[1]')));
    });

    test('returns empty text when the input contains only a URL', () {
      expect(prepareTextForSpeech('https://example.com'), isEmpty);
    });
  });

  group('splitTextForSpeech', () {
    test('preserves sentence order and limits every chunk', () {
      const source = '第一句很短。第二句也很短！第三句用于验证超长文本可以安全切分。';

      final chunks = splitTextForSpeech(source, maxChunkLength: 10);

      expect(chunks, isNotEmpty);
      expect(chunks.join(), source);
      expect(chunks.every((chunk) => chunk.characters.length <= 10), isTrue);
    });

    test('does not split a grapheme cluster in the middle', () {
      const source = '😀😀😀😀😀😀😀😀😀😀😀😀';

      final chunks = splitTextForSpeech(source, maxChunkLength: 5);

      expect(chunks.map((chunk) => chunk.characters.length), [5, 5, 2]);
      expect(chunks.join(), source);
    });
  });

  test(
    'requires a configured API instead of falling back to local speech',
    () async {
      final service = ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(),
      );
      addTearDown(service.dispose);

      await service.speak(
        const TextToSpeechRequest(
          messageId: 'assistant-1',
          text: '你好。',
          apiConfig: null,
          apiKey: '',
        ),
      );

      expect(service.playback.value.phase, TextToSpeechPhase.error);
      expect(service.playback.value.errorMessage, contains('配置云端语音合成 API'));
    },
  );

  test('size-limit abort during synthesis surfaces an error instead of '
      'staying stuck on loading', () async {
    // The provider cancels the shared token when the stream exceeds the
    // size limit; the service must tell that abort apart from a
    // user-initiated stop and surface it as an error.
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException.requestCancelled(
                requestOptions: options,
                reason: OpenAiCompatibleMediaProvider.ttsSizeLimitCancelReason,
              ),
            );
          },
        ),
      );
    final service = ApiTextToSpeechService(
      mediaProvider: OpenAiCompatibleMediaProvider(dio: dio),
    );
    addTearDown(service.dispose);

    await service.speak(
      const TextToSpeechRequest(
        messageId: 'assistant-1',
        text: '你好。',
        apiConfig: MediaApiConfig(
          baseUrl: 'http://placeholder',
          model: 'tts-1',
        ),
        apiKey: 'secret',
      ),
    );

    await waitForPhase(service, TextToSpeechPhase.error);
    expect(service.playback.value.errorMessage, contains('25 MB'));
  });

  test('a user-initiated stop leaves playback idle, not error', () async {
    final release = Completer<void>();
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await release.future;
            handler.reject(
              DioException.requestCancelled(
                requestOptions: options,
                reason: '朗读已停止',
              ),
            );
          },
        ),
      );
    final service = ApiTextToSpeechService(
      mediaProvider: OpenAiCompatibleMediaProvider(dio: dio),
    );
    addTearDown(service.dispose);

    await service.speak(
      const TextToSpeechRequest(
        messageId: 'assistant-1',
        text: '你好。',
        apiConfig: MediaApiConfig(
          baseUrl: 'http://placeholder',
          model: 'tts-1',
        ),
        apiKey: 'secret',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final stopFuture = service.stop();
    release.complete();
    await stopFuture;
    // Let the in-flight request's cancel land in the error handler.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(service.playback.value.phase, TextToSpeechPhase.idle);
    expect(service.playback.value.errorMessage, isNull);
  });

  test(
    'surfaces the provider error detail instead of the fixed fallback',
    () async {
      // The provider already humanizes DioExceptions into
      // Exception('语音生成失败（400）：Invalid API key provided'); the
      // service must show that detail rather than overwrite it with the
      // generic "check your API configuration" copy.
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<List<int>>(
                    requestOptions: options,
                    statusCode: 400,
                    data: utf8.encode(
                      jsonEncode({
                        'error': {'message': 'Invalid API key provided'},
                      }),
                    ),
                  ),
                ),
              );
            },
          ),
        );
      final service = ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(dio: dio),
      );
      addTearDown(service.dispose);

      await service.speak(
        const TextToSpeechRequest(
          messageId: 'assistant-1',
          text: '你好。',
          apiConfig: MediaApiConfig(
            baseUrl: 'http://placeholder',
            model: 'tts-1',
          ),
          apiKey: 'secret',
        ),
      );

      await waitForPhase(service, TextToSpeechPhase.error);
      expect(
        service.playback.value.errorMessage,
        contains('Invalid API key provided'),
      );
      expect(service.playback.value.errorMessage, contains('语音生成失败（400）'));
    },
  );

  test(
    'web placeholder surfaces an explicit unsupported-platform error',
    () async {
      // Browser builds resolve ApiTextToSpeechService to the stub below: it must
      // not pretend synthesis ran and then fail with the misleading "check your
      // API configuration" message - it says the platform is unsupported.
      final service = web_tts.ApiTextToSpeechService(
        mediaProvider: OpenAiCompatibleMediaProvider(),
      );
      addTearDown(service.dispose);

      await service.speak(
        const TextToSpeechRequest(
          messageId: 'assistant-1',
          text: '你好。',
          apiConfig: MediaApiConfig(
            baseUrl: 'http://placeholder',
            model: 'tts-1',
          ),
          apiKey: 'secret',
        ),
      );

      expect(service.playback.value.phase, TextToSpeechPhase.error);
      expect(service.playback.value.errorMessage, contains('当前平台不支持语音朗读'));
    },
  );
}
