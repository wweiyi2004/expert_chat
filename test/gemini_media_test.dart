import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_state.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/media/image_edit_reference.dart';
import 'package:expert_chat/domain/media/image_generation_service.dart';
import 'package:expert_chat/domain/media/image_prompt_optimizer.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:expert_chat/domain/tools/vision_tool_executor.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _imagePart(String data, {bool thought = false}) => {
  if (thought) 'thought': true,
  'inlineData': {'mimeType': 'image/png', 'data': data},
};

Map<String, dynamic> _candidate(
  List<Map<String, dynamic>> parts, {
  String reason = 'STOP',
}) => {
  'candidates': [
    {
      'finishReason': reason,
      'content': {'role': 'model', 'parts': parts},
    },
  ],
};

ResponseBody _json(Object data, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(data),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

const _native = MediaApiConfig(
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  model: 'gemini-3-pro-image',
  apiFormat: LlmApiFormat.geminiNative,
);

class _CaptureLlm implements LlmProvider {
  LlmConfig? receivedConfig;
  List<LlmRequestMessage>? receivedMessages;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    receivedConfig = config;
    receivedMessages = messages;
    yield const ChatChunk(contentDelta: 'visible object');
  }
}

void main() {
  test(
    'vision and prompt optimization retain the configured native wire format',
    () async {
      final relay = _native.copyWith(baseUrl: 'https://relay.example/v1');
      final settings = SettingsState(
        visionApi: relay,
        visionApiKey: 'vision-key',
        profiles: [
          ProviderProfile(
            id: 'native',
            name: 'native',
            baseUrl: relay.baseUrl,
            chatModel: 'gemini-3-flash',
            reasonerModel: 'gemini-3-pro',
            apiFormat: LlmApiFormat.geminiNative,
          ),
        ],
        activeProfileId: 'native',
        apiKey: 'chat-key',
      );
      final llm = _CaptureLlm();
      await VisionToolExecutor(
        getProvider: () => llm,
        onActivity: (_) {},
        checkBudget: () => (allowed: true, reason: null),
      ).analyze(
        config: settings.visionConfig,
        image: Attachment(
          name: 'source.png',
          mimeType: 'image/png',
          sizeBytes: 3,
          imageBase64: 'AQID',
        ),
        question: 'describe it',
        cancelToken: CancelToken(),
      );
      expect(llm.receivedConfig!.apiFormat, LlmApiFormat.geminiNative);
      expect(llm.receivedConfig!.apiKey, 'vision-key');
      expect(llm.receivedMessages!.last.imageDataUrls, [
        'data:image/png;base64,AQID',
      ]);
      await ImagePromptOptimizer(getProvider: () => llm).optimize(
        userPrompt: 'draw a landscape',
        config: settings.config.copyWith(model: 'gemini-3-pro'),
        cancelToken: CancelToken(),
        onReasoning: (_, _) {},
      );
      expect(llm.receivedConfig!.apiFormat, LlmApiFormat.geminiNative);
      expect(llm.receivedConfig!.apiKey, 'chat-key');
      expect(llm.receivedConfig!.model, 'gemini-3-pro');
    },
  );
  for (final entry in <String, Map<String, String>>{
    '1024x1024': {'aspectRatio': '1:1'},
    '1536x1024': {'aspectRatio': '3:2'},
    '1024x1536': {'aspectRatio': '2:3'},
    '1920x1080': {'aspectRatio': '16:9'},
    '4:3': {'aspectRatio': '4:3'},
    '21:9': {'aspectRatio': '21:9'},
    '2k': {'imageSize': '2K'},
    '4K': {'imageSize': '4K'},
    '512': {'imageSize': '512'},
  }.entries) {
    test('Gemini sends exact image config for ${entry.key}', () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          final body = jsonDecode(request.data as String) as Map;
          expect(body['generationConfig'], {
            'responseModalities': ['TEXT', 'IMAGE'],
            'imageConfig': entry.value,
          });
          expect(
            request.uri.path,
            '/v1beta/models/gemini-3-pro-image:generateContent',
          );
          expect(request.headers['x-goog-api-key'], 'AIza-test');
          expect(request.headers.containsKey('Authorization'), isFalse);
          return _json(_candidate([_imagePart('AQID')]));
        });
      await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: _native.copyWith(imageSize: entry.key),
        apiKey: 'AIza-test',
        prompt: 'landscape',
      );
    });
  }

  test('auto leaves native image configuration to the model', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        expect(
          (jsonDecode(request.data as String) as Map)['generationConfig'],
          {
            'responseModalities': ['TEXT', 'IMAGE'],
          },
        );
        return _json(_candidate([_imagePart('AQID')]));
      });
    await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
      config: _native.copyWith(imageSize: 'auto'),
      apiKey: 'key',
      prompt: 'image',
    );
  });

  test(
    'image service preserves explicit native protocol and reference order on a relay',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          expect(
            request.uri.path,
            '/relay/v1beta/models/gemini-3-pro-image:generateContent',
          );
          expect(request.headers['x-goog-api-key'], 'relay-key');
          final body = jsonDecode(request.data as String) as Map;
          final parts = ((body['contents'] as List).single as Map)['parts'];
          expect(parts, [
            {
              'inlineData': {'mimeType': 'image/png', 'data': 'AQI='},
            },
            {
              'inlineData': {'mimeType': 'image/jpeg', 'data': 'AwQ='},
            },
            {'text': 'use both'},
          ]);
          return _json(_candidate([_imagePart('AQID')]));
        });
      final config = MediaApiConfig.fromJson(
        _native
            .copyWith(
              baseUrl: 'https://relay.example/relay/v1beta',
              imageSize: 'auto',
            )
            .toJson(),
      ).copyWith(model: 'gemini-3-pro-image');
      final result =
          await ImageGenerationService(
            getProvider: () => OpenAiCompatibleMediaProvider(dio: dio),
          ).generate(
            config: config,
            apiKey: 'relay-key',
            prompt: ' use both ',
            cancelToken: CancelToken(),
            references: [
              ImageEditReference(
                bytes: [1, 2],
                mimeType: 'image/png',
                fileName: 'one.png',
              ),
              ImageEditReference(
                bytes: [3, 4],
                mimeType: 'image/jpeg',
                fileName: 'two.jpg',
              ),
            ],
          );
      expect(result.response.base64, 'AQID');
      expect(config.apiFormat, LlmApiFormat.geminiNative);
    },
  );

  test('Gemini never presents thought images as the final image', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (_) => _json(
          _candidate([
            _imagePart('AQID', thought: true),
            {'thought': true, 'text': 'internal sketch'},
            {'text': 'final description'},
            {
              'inlineData': {'mimeType': 'image/jpeg', 'data': 'BAUG'},
            },
          ]),
        ),
      );
    final result = await OpenAiCompatibleMediaProvider(
      dio: dio,
    ).generateImage(config: _native, apiKey: 'key', prompt: 'image');
    expect(result.base64, 'BAUG');
    expect(result.mimeType, 'image/jpeg');
    expect(result.revisedPrompt, 'final description');
  });

  for (final response in <Map<String, dynamic>>[
    _candidate([_imagePart('AQID', thought: true)]),
    _candidate([
      {
        'inlineData': {'mimeType': 'audio/wav', 'data': 'AQID'},
      },
    ]),
    _candidate([]),
    {'candidates': []},
  ]) {
    test('missing final image fails (${jsonEncode(response)})', () async {
      final dio = Dio()..httpClientAdapter = _Adapter((_) => _json(response));
      await expectLater(
        OpenAiCompatibleMediaProvider(
          dio: dio,
        ).generateImage(config: _native, apiKey: 'key', prompt: 'image'),
        throwsA(isA<FormatException>()),
      );
    });
  }

  for (final reason in ['SAFETY', 'IMAGE_SAFETY', 'NO_IMAGE', 'MAX_TOKENS']) {
    test('native image failure preserves finish reason $reason', () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _json(
            _candidate([_imagePart('AQID', thought: true)], reason: reason),
          ),
        );
      await expectLater(
        OpenAiCompatibleMediaProvider(
          dio: dio,
        ).generateImage(config: _native, apiKey: 'key', prompt: 'image'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains(reason),
          ),
        ),
      );
    });
  }

  test('prompt blocking reports server reason and message', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (_) => _json({
          'promptFeedback': {
            'blockReason': 'IMAGE_SAFETY',
            'blockReasonMessage': 'request blocked',
          },
        }),
      );
    await expectLater(
      OpenAiCompatibleMediaProvider(
        dio: dio,
      ).generateImage(config: _native, apiKey: 'key', prompt: 'image'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('IMAGE_SAFETY'), contains('request blocked')),
        ),
      ),
    );
  });

  test(
    'plain model explanation is surfaced when it returns no image',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _json(
            _candidate([
              {'text': 'This model only supports text output.'},
            ]),
          ),
        );
      await expectLater(
        OpenAiCompatibleMediaProvider(
          dio: dio,
        ).generateImage(config: _native, apiKey: 'key', prompt: 'image'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('only supports text'),
          ),
        ),
      );
    },
  );

  test('relay errors in successful HTTP envelopes remain failures', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (_) => _json({
          'error': {'code': 403, 'message': 'model permission missing'},
        }),
      );
    await expectLater(
      OpenAiCompatibleMediaProvider(
        dio: dio,
      ).generateImage(config: _native, apiKey: 'key', prompt: 'image'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('permission missing'),
        ),
      ),
    );
  });

  for (final status in [401, 403, 429]) {
    test('HTTP $status produces actionable media error', () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (_) => _json({
            'error': {'message': 'check project entitlement'},
          }, status: status),
        );
      await expectLater(
        OpenAiCompatibleMediaProvider(
          dio: dio,
        ).generateImage(config: _native, apiKey: 'key', prompt: 'image'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('$status'),
          ),
        ),
      );
    });
  }

  test(
    'Imagen proxy retains predict and a supported exact aspect ratio',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          expect(
            request.uri.path,
            '/v1beta/models/imagen-4.0-generate-001:predict',
          );
          expect((jsonDecode(request.data as String) as Map)['parameters'], {
            'sampleCount': 1,
            'aspectRatio': '4:3',
          });
          return _json({
            'predictions': [
              {'bytesBase64Encoded': 'AQID', 'mimeType': 'image/png'},
            ],
          });
        });
      await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: _native.copyWith(
          baseUrl: 'https://relay.example/v1beta',
          model: 'imagen-4.0-generate-001',
          imageSize: '4:3',
        ),
        apiKey: 'key',
        prompt: 'image',
      );
    },
  );

  test('Imagen does not silently change a 3:2 request into 16:9', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((_) => throw StateError('must not send'));
    await expectLater(
      OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: _native.copyWith(
          model: 'imagen-4.0-generate-001',
          imageSize: '1536x1024',
        ),
        apiKey: 'key',
        prompt: 'image',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('3:2'),
        ),
      ),
    );
  });

  test(
    'Imagen resolution uses its documented sampleImageSize wire field',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          expect((jsonDecode(request.data as String) as Map)['parameters'], {
            'sampleCount': 1,
            'sampleImageSize': '2K',
          });
          return _json({
            'predictions': [
              {'bytesBase64Encoded': 'AQID', 'mimeType': 'image/png'},
            ],
          });
        });
      await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: _native.copyWith(
          model: 'imagen-4.0-generate-001',
          imageSize: '2K',
        ),
        apiKey: 'key',
        prompt: 'image',
      );
    },
  );

  test('Imagen reports filtered results', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (_) => _json({
          'predictions': [
            {'raiFilteredReason': 'filtered by service'},
          ],
        }),
      );
    await expectLater(
      OpenAiCompatibleMediaProvider(dio: dio).generateImage(
        config: _native.copyWith(model: 'imagen-4.0-generate-001'),
        apiKey: 'key',
        prompt: 'image',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('filtered by service'),
        ),
      ),
    );
  });

  test(
    'native speech configuration is rejected before OpenAI audio is called',
    () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (_) => throw StateError('must not send'),
        );
      await expectLater(
        OpenAiCompatibleMediaProvider(
          dio: dio,
        ).synthesizeSpeech(config: _native, apiKey: 'key', text: 'hello'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('不支持 Gemini 原生'),
          ),
        ),
      );
    },
  );

  test(
    'too many native references fail instead of silently dropping them',
    () async {
      expect(_native.maxImageEditReferences, 14);
      final dio = Dio()
        ..httpClientAdapter = _Adapter(
          (_) => throw StateError('must not send'),
        );
      await expectLater(
        OpenAiCompatibleMediaProvider(dio: dio).generateImage(
          config: _native,
          apiKey: 'key',
          prompt: 'image',
          referenceImages: List.generate(
            15,
            (i) => ImageEditReference(
              bytes: [i],
              mimeType: 'image/png',
              fileName: '$i.png',
            ),
          ),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('14'),
          ),
        ),
      );
    },
  );

  test('native ASR configuration cannot issue a MiMo request', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((_) => throw StateError('must not send'));
    await expectLater(
      OpenAiCompatibleMediaProvider(dio: dio).transcribeMimoSpeech(
        config: _native,
        apiKey: 'key',
        audioBytes: Uint8List.fromList([1, 2]),
        mimeType: 'audio/wav',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('不支持 Gemini 原生'),
        ),
      ),
    );
  });

  test('explicit OpenAI image protocol stays on images/generations', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter((request) {
        expect(request.uri.path, '/v1/images/generations');
        expect(request.headers['Authorization'], 'Bearer key');
        expect(request.headers.containsKey('x-goog-api-key'), isFalse);
        expect(
          (jsonDecode(request.data as String) as Map)['size'],
          '1536x1024',
        );
        return _json({
          'data': [
            {'b64_json': 'AQID'},
          ],
        });
      });
    await OpenAiCompatibleMediaProvider(dio: dio).generateImage(
      config: _native.copyWith(
        baseUrl: 'https://relay.example/v1',
        apiFormat: LlmApiFormat.openAiCompatible,
        imageSize: '1536x1024',
      ),
      apiKey: 'key',
      prompt: 'image',
    );
  });
}
