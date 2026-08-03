import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/domain/media/image_edit_reference.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';

void main() {
  group('MediaApiConfig', () {
    test('gpt-image models allow multi reference images', () {
      expect(
        const MediaApiConfig(model: 'gpt-image-2').supportsMultiReferenceImages,
        isTrue,
      );
      expect(
        const MediaApiConfig(model: 'gpt-image-2').maxImageEditReferences,
        MediaApiConfig.maxGptImageEditReferences,
      );
      expect(
        const MediaApiConfig(model: 'dall-e-3').supportsMultiReferenceImages,
        isFalse,
      );
      expect(const MediaApiConfig(model: 'dall-e-3').maxImageEditReferences, 1);
      expect(
        MediaApiConfig.supportsMultiReferenceImageModel('openai/gpt-image-1'),
        isTrue,
      );
    });

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

    test('voice is optional and never gates the configured badge', () {
      // The OpenAI-compatible path falls back to 'alloy' and the MiMo path to
      // mimoDefaultVoice, so an empty voice still counts as configured.
      const config = MediaApiConfig(
        baseUrl: 'https://example.com/v1',
        model: 'tts-1',
        voice: '',
      );

      expect(config.isConfiguredWith('secret'), isTrue);
      expect(config.isConfiguredWith(''), isFalse);
    });

    test('round-trips optional fields', () {
      const original = MediaApiConfig(
        baseUrl: 'https://example.com/v1',
        model: 'image-1',
        voice: 'nova',
        voiceDesignPrompt: '温柔女声',
        voiceClonePath: r'C:\voices\me.wav',
        imageSize: '1536x1024',
        speechProtocol: SpeechApiProtocol.mimoChatCompletions,
      );

      final restored = MediaApiConfig.fromJson(original.toJson());
      expect(restored.baseUrl, original.baseUrl);
      expect(restored.model, original.model);
      expect(restored.voice, original.voice);
      expect(restored.voiceDesignPrompt, original.voiceDesignPrompt);
      expect(restored.voiceClonePath, original.voiceClonePath);
      expect(restored.imageSize, original.imageSize);
      expect(restored.speechProtocol, original.speechProtocol);
    });

    test('maps MiMo TTS model ids to builtin/design/clone modes', () {
      expect(
        const MediaApiConfig(model: MediaApiConfig.mimoTtsModel).mimoTtsMode,
        MimoTtsMode.builtin,
      );
      expect(
        const MediaApiConfig(
          model: MediaApiConfig.mimoTtsDesignModel,
        ).mimoTtsMode,
        MimoTtsMode.design,
      );
      expect(
        const MediaApiConfig(
          model: MediaApiConfig.mimoTtsCloneModel,
        ).mimoTtsMode,
        MimoTtsMode.clone,
      );
      expect(
        MediaApiConfig.modelForMimoTtsMode(
          MimoTtsMode.design,
          MediaApiConfig.mimoTtsModel,
        ),
        MediaApiConfig.mimoTtsDesignModel,
      );
      expect(
        MediaApiConfig.mimoBuiltinVoices.map((v) => v.id),
        containsAll(['mimo_default', '冰糖', '茉莉', '苏打', '白桦', 'Mia', 'Chloe']),
      );
    });

    test('detects MiMo speech endpoints from host or model id', () {
      expect(
        const MediaApiConfig(
          baseUrl: MediaApiConfig.mimoBaseUrl,
          model: 'anything',
        ).looksLikeMimoSpeechEndpoint,
        isTrue,
      );
      expect(
        const MediaApiConfig(
          baseUrl: 'https://proxy.example.com/v1',
          model: MediaApiConfig.mimoTtsModel,
        ).looksLikeMimoSpeechEndpoint,
        isTrue,
      );
      expect(
        const MediaApiConfig(
          baseUrl: 'https://api.openai.com/v1',
          model: 'tts-1',
        ).looksLikeMimoSpeechEndpoint,
        isFalse,
      );
    });

    test(
      'effectiveSpeechProtocol upgrades forgotten OpenAI default on MiMo',
      () {
        const misconfigured = MediaApiConfig(
          baseUrl: MediaApiConfig.mimoBaseUrl,
          model: MediaApiConfig.mimoTtsModel,
          // Deliberately left at the form default — the common user miss.
          speechProtocol: SpeechApiProtocol.openAiAudio,
        );
        expect(
          misconfigured.effectiveSpeechProtocol,
          SpeechApiProtocol.mimoChatCompletions,
        );
        expect(
          MediaApiConfig.inferSpeechProtocol(
            baseUrl: MediaApiConfig.mimoBaseUrl,
            model: MediaApiConfig.mimoTtsModel,
            current: SpeechApiProtocol.openAiAudio,
          ),
          SpeechApiProtocol.mimoChatCompletions,
        );
        // Non-MiMo hosts keep an explicit OpenAI choice.
        expect(
          MediaApiConfig.inferSpeechProtocol(
            baseUrl: 'https://api.openai.com/v1',
            model: 'tts-1',
            current: SpeechApiProtocol.openAiAudio,
          ),
          SpeechApiProtocol.openAiAudio,
        );
      },
    );

    test(
      'detects Alibaba Model Studio TTS models and selects its protocol',
      () {
        const qwen3 = MediaApiConfig(
          baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
          model: MediaApiConfig.aliyunQwen3TtsModel,
        );
        expect(qwen3.looksLikeAliyunSpeechEndpoint, isTrue);
        expect(
          qwen3.effectiveSpeechProtocol,
          SpeechApiProtocol.aliyunModelStudio,
        );
        expect(qwen3.aliyunDefaultVoice, 'Cherry');
        expect(
          qwen3.aliyunBuiltinVoices.map((voice) => voice.id),
          contains('Chelsie'),
        );

        const qwenAudio = MediaApiConfig(
          baseUrl: 'https://workspace123.cn-beijing.maas.aliyuncs.com/api/v1',
          model: MediaApiConfig.aliyunQwenAudioTtsModel,
        );
        expect(qwenAudio.hasAliyunWorkspaceBaseUrl, isTrue);
        expect(qwenAudio.aliyunDefaultVoice, 'longanhuan_v3.6');

        const cosy = MediaApiConfig(
          baseUrl: 'https://workspace123.cn-beijing.maas.aliyuncs.com/api/v1',
          model: MediaApiConfig.aliyunCosyVoiceTtsModel,
        );
        expect(cosy.aliyunBuiltinVoices, isEmpty);
        expect(cosy.aliyunDefaultVoice, isEmpty);
      },
    );
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

    test('gpt-image multi-ref sends repeated image[] parts', () async {
      late FormData form;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              form = options.data as FormData;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': [
                      {'b64_json': base64Encode(const [9, 9])},
                    ],
                  },
                ),
              );
            },
          ),
        );

      await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: const MediaApiConfig(
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-image-2',
        ),
        apiKey: 'secret',
        prompt: 'gift basket',
        referenceImages: const [
          ImageEditReference(bytes: [1], fileName: 'a.png'),
          ImageEditReference(bytes: [2], fileName: 'b.png'),
          ImageEditReference(bytes: [3], fileName: 'c.png'),
        ],
      );

      final imageParts = form.files.where((e) => e.key == 'image[]').toList();
      expect(imageParts, hasLength(3));
      expect(form.files.any((e) => e.key == 'image'), isFalse);
    });

    test('legacy single-ref still uses image field name', () async {
      late FormData form;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              form = options.data as FormData;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': [
                      {'b64_json': base64Encode(const [1])},
                    ],
                  },
                ),
              );
            },
          ),
        );

      await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: const MediaApiConfig(
          baseUrl: 'https://example.com/v1',
          model: 'dall-e-2',
        ),
        apiKey: 'secret',
        prompt: 'edit',
        referenceImageBytes: const [1, 2, 3],
      );

      expect(form.files.where((e) => e.key == 'image'), hasLength(1));
      expect(form.files.any((e) => e.key == 'image[]'), isFalse);
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
      expect(audio.bytes, <int>[10, 20, 30]);
      expect(audio.fileExtension, 'mp3');
    });

    test('sends a non-default TTS speed when requested', () async {
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

      await OpenAiCompatibleMediaProvider(dio: dio).synthesizeSpeech(
        config: const MediaApiConfig(
          baseUrl: 'https://example.com/v1',
          model: 'tts-1',
        ),
        apiKey: 'secret',
        text: '你好',
        speed: 1.24,
      );

      expect(jsonDecode(captured.data as String)['speed'], 1.24);
    });

    test('uses DashScope Qwen3 TTS and downloads the returned WAV', () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              if (options.method == 'POST') {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'status_code': 200,
                      'output': {
                        'finish_reason': 'stop',
                        'audio': {
                          'url': 'https://audio.example.com/result.wav',
                          'data': '',
                        },
                      },
                    },
                  ),
                );
                return;
              }
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <int>[0x52, 0x49, 0x46, 0x46, 1, 2, 3],
                  headers: Headers.fromMap({
                    Headers.contentTypeHeader: ['audio/wav'],
                  }),
                ),
              );
            },
          ),
        );

      final audio = await OpenAiCompatibleMediaProvider(dio: dio)
          .synthesizeSpeech(
            config: const MediaApiConfig(
              baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
              model: MediaApiConfig.aliyunQwen3TtsModel,
              voice: 'Chelsie',
              voiceDesignPrompt: '温柔、俏皮，像朋友聊天。',
              // Auto-detection must still route correctly when an older saved
              // config left the OpenAI protocol default behind.
              speechProtocol: SpeechApiProtocol.openAiAudio,
            ),
            apiKey: 'dashscope-secret',
            text: '你好，今天过得怎么样？',
          );

      expect(requests, hasLength(2));
      expect(
        requests.first.uri.toString(),
        '${MediaApiConfig.aliyunModelStudioBaseUrl}/services/aigc/'
        'multimodal-generation/generation',
      );
      final body =
          jsonDecode(requests.first.data as String) as Map<String, dynamic>;
      expect(body['model'], MediaApiConfig.aliyunQwen3TtsModel);
      expect(body['input'], {
        'text': '你好，今天过得怎么样？',
        'voice': 'Chelsie',
        'language_type': 'Chinese',
        'instructions': '温柔、俏皮，像朋友聊天。',
        'optimize_instructions': true,
      });
      expect(
        requests.last.uri.toString(),
        'https://audio.example.com/result.wav',
      );
      expect(audio.bytes, <int>[0x52, 0x49, 0x46, 0x46, 1, 2, 3]);
      expect(audio.fileExtension, 'wav');
      expect(audio.mimeType, 'audio/wav');
    });

    test('uses workspace SpeechSynthesizer for Qwen-Audio TTS', () async {
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
                    'output': {
                      'finish_reason': 'stop',
                      'audio': {
                        'url': '',
                        'data': base64Encode(const [0x49, 0x44, 0x33, 1]),
                      },
                    },
                  },
                ),
              );
            },
          ),
        );

      final audio = await OpenAiCompatibleMediaProvider(dio: dio)
          .synthesizeSpeech(
            config: const MediaApiConfig(
              baseUrl:
                  'https://workspace123.cn-beijing.maas.aliyuncs.com/api/v1',
              model: MediaApiConfig.aliyunQwenAudioTtsModel,
              voice: '',
              voiceDesignPrompt: '轻快明亮',
              speechProtocol: SpeechApiProtocol.aliyunModelStudio,
            ),
            apiKey: 'dashscope-secret',
            text: '低延迟测试',
            speed: 1.25,
          );

      expect(
        captured.uri.toString(),
        'https://workspace123.cn-beijing.maas.aliyuncs.com/api/v1/'
        'services/audio/tts/SpeechSynthesizer',
      );
      final body = jsonDecode(captured.data as String) as Map<String, dynamic>;
      expect(body['model'], MediaApiConfig.aliyunQwenAudioTtsModel);
      expect(body['input'], {
        'text': '低延迟测试',
        'voice': MediaApiConfig.aliyunQwenAudioDefaultVoice,
        'format': 'mp3',
        'sample_rate': 24000,
        'rate': 1.25,
        'instruction': '轻快明亮',
      });
      expect(audio.bytes, <int>[0x49, 0x44, 0x33, 1]);
      expect(audio.fileExtension, 'mp3');
    });

    test('explains the workspace URL requirement before Qwen-Audio call', () {
      final provider = OpenAiCompatibleMediaProvider(dio: Dio());
      expect(
        () => provider.synthesizeSpeech(
          config: const MediaApiConfig(
            baseUrl: MediaApiConfig.aliyunModelStudioBaseUrl,
            model: MediaApiConfig.aliyunQwenAudioTtsModel,
            speechProtocol: SpeechApiProtocol.aliyunModelStudio,
          ),
          apiKey: 'secret',
          text: '测试',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Workspace Base URL'),
          ),
        ),
      );
    });

    test('uses MiMo chat completions for TTS and decodes WAV audio', () async {
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
                        'message': {
                          'audio': {
                            'data': base64Encode(const [82, 73, 70]),
                          },
                        },
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );

      final audio = await OpenAiCompatibleMediaProvider(dio: dio)
          .synthesizeSpeech(
            config: const MediaApiConfig(
              baseUrl: MediaApiConfig.mimoBaseUrl,
              model: MediaApiConfig.mimoTtsModel,
              voice: MediaApiConfig.mimoDefaultVoice,
              speechProtocol: SpeechApiProtocol.mimoChatCompletions,
            ),
            apiKey: 'secret',
            text: '你好，世界。',
          );

      expect(
        captured.uri.toString(),
        '${MediaApiConfig.mimoBaseUrl}/chat/completions',
      );
      final body = jsonDecode(captured.data as String) as Map<String, dynamic>;
      expect(body['model'], MediaApiConfig.mimoTtsModel);
      expect((body['messages'] as List)[1], {
        'role': 'assistant',
        'content': '你好，世界。',
      });
      expect(body['audio'], {
        'format': 'wav',
        'voice': MediaApiConfig.mimoDefaultVoice,
      });
      expect(audio.bytes, <int>[82, 73, 70]);
      expect(audio.fileExtension, 'wav');
      expect(audio.mimeType, 'audio/wav');
    });

    test(
      'routes MiMo TTS via chat/completions even when protocol was left OpenAI',
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
                          'message': {
                            'audio': {
                              'data': base64Encode(const [1, 2, 3]),
                            },
                          },
                        },
                      ],
                    },
                  ),
                );
              },
            ),
          );

        await OpenAiCompatibleMediaProvider(dio: dio).synthesizeSpeech(
          config: const MediaApiConfig(
            baseUrl: MediaApiConfig.mimoBaseUrl,
            model: MediaApiConfig.mimoTtsModel,
            // Saved default — must not POST /audio/speech.
            speechProtocol: SpeechApiProtocol.openAiAudio,
          ),
          apiKey: 'secret',
          text: '自动纠偏',
        );

        expect(
          captured.uri.toString(),
          '${MediaApiConfig.mimoBaseUrl}/chat/completions',
        );
      },
    );

    test(
      'MiMo voice design sends description as user content without voice id',
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
                          'message': {
                            'audio': {
                              'data': base64Encode(const [1, 2, 3]),
                            },
                          },
                        },
                      ],
                    },
                  ),
                );
              },
            ),
          );

        await OpenAiCompatibleMediaProvider(dio: dio).synthesizeSpeech(
          config: const MediaApiConfig(
            baseUrl: MediaApiConfig.mimoBaseUrl,
            model: MediaApiConfig.mimoTtsDesignModel,
            voiceDesignPrompt: '二十多岁年轻女性，声音清亮。',
            speechProtocol: SpeechApiProtocol.mimoChatCompletions,
          ),
          apiKey: 'secret',
          text: '晚上好。',
        );

        final body =
            jsonDecode(captured.data as String) as Map<String, dynamic>;
        expect(body['model'], MediaApiConfig.mimoTtsDesignModel);
        expect((body['messages'] as List).first, {
          'role': 'user',
          'content': '二十多岁年轻女性，声音清亮。',
        });
        expect(body['audio'], {
          'format': 'wav',
          'optimize_text_preview': false,
        });
        expect((body['audio'] as Map).containsKey('voice'), isFalse);
      },
    );

    test('MiMo voice clone sends sample as data URI voice', () async {
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
                        'message': {
                          'audio': {
                            'data': base64Encode(const [9, 9, 9]),
                          },
                        },
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );

      const sample = <int>[11, 22, 33, 44];
      await OpenAiCompatibleMediaProvider(dio: dio).synthesizeSpeech(
        config: const MediaApiConfig(
          baseUrl: MediaApiConfig.mimoBaseUrl,
          model: MediaApiConfig.mimoTtsCloneModel,
          speechProtocol: SpeechApiProtocol.mimoChatCompletions,
        ),
        apiKey: 'secret',
        text: '克隆试读。',
        voiceSampleBytes: Uint8List.fromList(sample),
        voiceSampleMimeType: 'audio/mpeg',
      );

      final body = jsonDecode(captured.data as String) as Map<String, dynamic>;
      expect(body['model'], MediaApiConfig.mimoTtsCloneModel);
      expect(body['audio'], {
        'format': 'wav',
        'voice': 'data:audio/mpeg;base64,${base64Encode(sample)}',
      });
    });

    test('MiMo voice design without prompt fails with a clear error', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              fail('must not call the network without a design prompt');
            },
          ),
        );

      expect(
        () => OpenAiCompatibleMediaProvider(dio: dio).synthesizeSpeech(
          config: const MediaApiConfig(
            baseUrl: MediaApiConfig.mimoBaseUrl,
            model: MediaApiConfig.mimoTtsDesignModel,
            speechProtocol: SpeechApiProtocol.mimoChatCompletions,
          ),
          apiKey: 'secret',
          text: '缺少描述',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('音色描述'),
          ),
        ),
      );
    });

    test('uses MiMo chat completions for ASR and returns transcript', () async {
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
                        'message': {'content': '  你好，MiMo。  '},
                      },
                    ],
                  },
                ),
              );
            },
          ),
        );

      final transcript = await OpenAiCompatibleMediaProvider(dio: dio)
          .transcribeMimoSpeech(
            config: const MediaApiConfig(
              baseUrl: MediaApiConfig.mimoBaseUrl,
              model: MediaApiConfig.mimoAsrModel,
            ),
            apiKey: 'secret',
            audioBytes: Uint8List.fromList(const [1, 2, 3]),
            mimeType: 'audio/wav',
          );

      expect(
        captured.uri.toString(),
        '${MediaApiConfig.mimoBaseUrl}/chat/completions',
      );
      final body = jsonDecode(captured.data as String) as Map<String, dynamic>;
      expect(body['model'], MediaApiConfig.mimoAsrModel);
      expect((body['messages'] as List).single, {
        'role': 'user',
        'content': [
          {
            'type': 'input_audio',
            'input_audio': {'data': 'data:audio/wav;base64,AQID'},
          },
        ],
      });
      expect(body['asr_options'], {'language': 'auto'});
      expect(transcript, '你好，MiMo。');
    });

    test(
      'aborts an oversized generated-image download with a clear error',
      () async {
        // The provider aborts the URL download itself once the stream would
        // exceed the 20 MB limit by cancelling the token with a dedicated
        // reason; that internal abort must surface as a content error, not
        // as a user cancellation.
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
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: OpenAiCompatibleMediaProvider
                        .imageDownloadSizeLimitCancelReason,
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
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('过大'),
            ),
          ),
        );
      },
    );

    test(
      'keeps user cancellation semantics for the image URL download',
      () async {
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
                // A user stop cancels the shared token with its own reason.
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: '朗读已停止',
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
          throwsA(isA<DioException>()),
        );
      },
    );

    test(
      'surfaces the server detail from a bytes-typed TTS error body',
      () async {
        // /audio/speech is fetched with ResponseType.bytes, so a non-2xx
        // error body arrives as raw UTF-8 bytes instead of a decoded map; the
        // service-level detail must still be parsed out of it.
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

        await expectLater(
          OpenAiCompatibleMediaProvider(dio: dio).synthesizeSpeech(
            config: const MediaApiConfig(
              baseUrl: 'https://example.com/v1',
              model: 'tts-1',
            ),
            apiKey: 'secret',
            text: '你好',
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('Invalid API key provided'),
            ),
          ),
        );
      },
    );

    test(
      'truncates a long server error message without splitting an emoji',
      () async {
        // 199 ASCII chars followed by an emoji: a 200-code-unit cut lands
        // inside the surrogate pair and produces a lone surrogate, which
        // corrupted the error banner. The cut must respect grapheme clusters.
        final message = '${'a' * 199}😀${'b' * 40}';
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: Response<dynamic>(
                      requestOptions: options,
                      statusCode: 400,
                      data: {
                        'error': {'message': message},
                      },
                    ),
                  ),
                );
              },
            ),
          );

        try {
          await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
            config: const MediaApiConfig(
              baseUrl: 'https://example.com/v1',
              model: 'image-1',
            ),
            apiKey: 'secret',
            prompt: 'a lighthouse',
          );
          fail('expected the request to fail');
        } on Exception catch (error) {
          final text = error.toString();
          expect(text, contains('😀'));
          // No lone surrogate (0xD800-0xDFFF) may survive the truncation.
          expect(
            text.runes.every((r) => !(r >= 0xD800 && r <= 0xDFFF)),
            isTrue,
          );
        }
      },
    );
  });
}
