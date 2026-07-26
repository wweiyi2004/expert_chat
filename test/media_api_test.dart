import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';

void main() {
  group('MediaApiConfig', () {
    test('is enabled only when endpoint, model and key are present', () {
      const config = MediaApiConfig(
        baseUrl: 'https://example.com/v1',
        model: 'vision-1',
      );

      expect(config.isConfiguredWith(''), isFalse);
      expect(config.isConfiguredWith('secret'), isTrue);
      expect(
        const MediaApiConfig(model: 'vision-1').isConfiguredWith('secret'),
        isFalse,
      );
      expect(
        const MediaApiConfig(
          baseUrl: 'not-a-url',
          model: 'vision-1',
        ).isConfiguredWith('secret'),
        isFalse,
      );
    });

    test('round-trips optional fields', () {
      const original = MediaApiConfig(
        baseUrl: 'https://example.com/v1',
        model: 'image-1',
        voice: 'nova',
        imageSize: '1536x1024',
      );

      final restored = MediaApiConfig.fromJson(original.toJson());
      expect(restored.baseUrl, original.baseUrl);
      expect(restored.model, original.model);
      expect(restored.voice, original.voice);
      expect(restored.imageSize, original.imageSize);
    });
  });

  group('OpenAiCompatibleMediaProvider', () {
    test(
      'parses base64 image output and builds the compatible endpoint',
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
                      'data': [
                        {
                          'b64_json': base64Encode(const [1, 2, 3, 4]),
                          'revised_prompt': 'a refined prompt',
                        },
                      ],
                    },
                  ),
                );
              },
            ),
          );
        final provider = OpenAiCompatibleMediaProvider(dio: dio);

        final image = await provider.generateImage(
          config: const MediaApiConfig(
            baseUrl: 'https://example.com/v1/',
            model: 'image-1',
            imageSize: '1024x1024',
          ),
          apiKey: 'secret',
          prompt: 'a lighthouse',
        );

        expect(
          captured.uri.toString(),
          'https://example.com/v1/images/generations',
        );
        expect(captured.headers['Authorization'], 'Bearer secret');
        expect(jsonDecode(captured.data as String), {
          'model': 'image-1',
          'prompt': 'a lighthouse',
          'size': '1024x1024',
        });
        expect(image.base64, base64Encode(const [1, 2, 3, 4]));
        expect(image.remoteUrl, isNull);
        expect(image.revisedPrompt, 'a refined prompt');
      },
    );

    test('accepts base64 payloads wrapped in whitespace by gateways', () async {
      final wrapped = base64Encode(
        List<int>.generate(48, (i) => i),
      ).replaceAllMapped(RegExp('.{8}'), (m) => '${m[0]}\n');
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'data': [
                    {'b64_json': wrapped},
                  ],
                },
              ),
            ),
          ),
        );
      final provider = OpenAiCompatibleMediaProvider(dio: dio);

      final image = await provider.generateImage(
        config: const MediaApiConfig(
          baseUrl: 'https://example.com/v1',
          model: 'image-1',
        ),
        apiKey: 'secret',
        prompt: 'a cat',
      );

      expect(image.base64, isNotNull);
      expect(base64Decode(image.base64!), hasLength(48));
    });

    test('rejects non-base64 image payloads', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'data': [
                    {'b64_json': 'not-valid!@#'},
                  ],
                },
              ),
            ),
          ),
        );
      final provider = OpenAiCompatibleMediaProvider(dio: dio);

      await expectLater(
        provider.generateImage(
          config: const MediaApiConfig(
            baseUrl: 'https://example.com/v1',
            model: 'image-1',
          ),
          apiKey: 'secret',
          prompt: 'a cat',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('accepts URL image output', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'data': [
                    {'url': 'https://cdn.example.com/generated.png'},
                  ],
                },
              ),
            ),
          ),
        );

      final image = await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: const MediaApiConfig(
          baseUrl: 'https://example.com/v1',
          model: 'image-1',
        ),
        apiKey: 'secret',
        prompt: 'a lighthouse',
      );

      expect(image.base64, isNull);
      expect(image.remoteUrl, 'https://cdn.example.com/generated.png');
    });

    test('returns binary TTS audio and sends voice', () async {
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
                  data: <int>[10, 20, 30],
                ),
              );
            },
          ),
        );

      final audio = await OpenAiCompatibleMediaProvider(dio: dio)
          .synthesizeSpeech(
            config: const MediaApiConfig(
              baseUrl: 'https://example.com/v1',
              model: 'tts-1',
              voice: 'nova',
            ),
            apiKey: 'secret',
            text: '你好',
          );

      expect(captured.uri.toString(), 'https://example.com/v1/audio/speech');
      expect(jsonDecode(captured.data as String), {
        'model': 'tts-1',
        'input': '你好',
        'voice': 'nova',
        'response_format': 'mp3',
      });
      expect(audio, <int>[10, 20, 30]);
    });
  });
}
