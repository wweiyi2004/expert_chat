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

    test('accepts URL-safe base64 and re-pads truncated payloads', () async {
      // '-' / '_' plus stripped padding: base64Decode accepts neither.
      final bytes = List<int>.generate(50, (i) => (i * 5) % 256);
      final urlSafe = base64Encode(
        bytes,
      ).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'data': [
                    {'b64_json': urlSafe},
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
        prompt: 'a cat',
      );

      expect(base64Decode(image.base64!), bytes);
    });

    test(
      'parses a multi-megabyte base64 image without blowing the stack',
      () async {
        // Regression: validating the payload with RegExp(r'^[A-Za-z0-9+/]+={0,2}$')
        // threw StackOverflowError on real generated images (2-8 MB of base64),
        // which surfaced in the chat as the bare error text "Stack Overflow".
        final bytes = List<int>.generate(3 * 1024 * 1024, (i) => i % 256);
        final payload = base64Encode(bytes);
        expect(payload.length, greaterThan(4 * 1000 * 1000));

        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': [
                      {'b64_json': payload},
                    ],
                  },
                ),
              ),
            ),
          );

        final image = await OpenAiCompatibleMediaProvider(dio: dio)
            .generateImage(
              config: const MediaApiConfig(
                baseUrl: 'https://example.com/v1',
                model: 'image-1',
              ),
              apiKey: 'secret',
              prompt: 'a lighthouse',
              referenceImageBytes: const [1, 2, 3, 4],
            );

        expect(image.base64, payload);
      },
    );

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

    test('embeds URL image output by downloading the bytes', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('/images/generations')) {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': [
                        {'url': 'https://cdn.example.com/generated.png'},
                      ],
                    },
                  ),
                );
                return;
              }
              // Download of the returned URL: respond with raw bytes.
              handler.resolve(
                Response<List<int>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const [1, 2, 3, 4, 5],
                ),
              );
            },
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

      expect(image.base64, base64Encode(const [1, 2, 3, 4, 5]));
      expect(image.remoteUrl, 'https://cdn.example.com/generated.png');
    });

    test('fails loudly when a returned URL cannot be downloaded', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('/images/generations')) {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': [
                        {'url': 'https://cdn.example.com/generated.png'},
                      ],
                    },
                  ),
                );
                return;
              }
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
            },
          ),
        );

      await expectLater(
        OpenAiCompatibleMediaProvider(dio: dio).generateImage(
          config: const MediaApiConfig(
            baseUrl: 'https://example.com/v1',
            model: 'image-1',
          ),
          apiKey: 'secret',
          prompt: 'a lighthouse',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('routes reference image to images/edits multipart', () async {
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
                        'b64_json': base64Encode(const [9, 8, 7]),
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );

      final image = await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: const MediaApiConfig(
          baseUrl: 'https://example.com/v1',
          model: 'image-1',
          imageSize: '1024x1024',
        ),
        apiKey: 'secret',
        prompt: 'make it rainy',
        referenceImageBytes: const [1, 2, 3, 4],
        referenceMimeType: 'image/png',
        referenceFileName: 'ref.png',
      );

      expect(captured.uri.toString(), 'https://example.com/v1/images/edits');
      expect(captured.data, isA<FormData>());
      final form = captured.data as FormData;
      final fieldMap = {for (final f in form.fields) f.key: f.value};
      expect(fieldMap['prompt'], 'make it rainy');
      expect(fieldMap['model'], 'image-1');
      expect(form.files, isNotEmpty);
      expect(form.files.first.key, 'image');
      // Gateways reject application/octet-stream parts as "invalid image".
      expect(form.files.first.value.contentType?.mimeType, 'image/png');
      expect(image.base64, base64Encode(const [9, 8, 7]));
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
