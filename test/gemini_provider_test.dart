import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/media_api_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/gemini_native_provider.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/llm/routing_llm_provider.dart';
import 'package:expert_chat/domain/media/image_edit_reference.dart';
import 'package:expert_chat/domain/media/openai_compatible_media_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHttpClientAdapter implements HttpClientAdapter {
  _FakeHttpClientAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('GeminiEndpoint detection & normalization', () {
    test('auto-detects native Gemini vs OpenAI-compatible URLs', () {
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        ),
        LlmApiFormat.geminiNative,
      );
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://generativelanguage.googleapis.com',
        ),
        LlmApiFormat.geminiNative,
      );
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://my-gemini-proxy.example.com/v1beta',
        ),
        LlmApiFormat.geminiNative,
      );
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        ),
        LlmApiFormat.openAiCompatible,
      );
      expect(
        GeminiEndpoint.resolveFormat(
          format: LlmApiFormat.auto,
          baseUrl: 'https://api.deepseek.com',
        ),
        LlmApiFormat.openAiCompatible,
      );
    });

    test('normalizes Gemini native action URLs and OpenAI-compatible URLs', () {
      expect(
        GeminiEndpoint.modelEndpoint(
          'https://generativelanguage.googleapis.com',
          'models/gemini-2.5-flash',
          'streamGenerateContent',
          sse: true,
        ),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
      );
      expect(
        GeminiEndpoint.modelEndpoint(
          'https://generativelanguage.googleapis.com/v1beta/openai',
          'google/gemini-2.5-pro',
          'generateContent',
        ),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent',
      );
      expect(
        GeminiEndpoint.normalizeOpenAiBaseUrl(
          'https://generativelanguage.googleapis.com/v1beta',
        ),
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(
        GeminiEndpoint.normalizeOpenAiBaseUrl(
          'https://generativelanguage.googleapis.com',
        ),
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(
        GeminiEndpoint.cleanUserInputBaseUrl(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent',
        ),
        'https://generativelanguage.googleapis.com/v1beta',
      );
    });

    test('ProviderProfile and MediaApiConfig serialize apiFormat', () {
      final profile = ProviderProfile(
        name: 'Gemini Native',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        chatModel: 'gemini-2.5-flash',
        reasonerModel: 'gemini-2.5-pro',
        apiFormat: LlmApiFormat.geminiNative,
      );
      final restoredProfile = ProviderProfile.fromJson(profile.toJson());
      expect(restoredProfile.apiFormat, LlmApiFormat.geminiNative);
      expect(restoredProfile.effectiveApiFormat, LlmApiFormat.geminiNative);

      const media = MediaApiConfig(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-flash-image',
        apiFormat: LlmApiFormat.geminiNative,
      );
      final restoredMedia = MediaApiConfig.fromJson(media.toJson());
      expect(restoredMedia.apiFormat, LlmApiFormat.geminiNative);
      expect(restoredMedia.isGeminiNative, isTrue);
      expect(restoredMedia.supportsMultiReferenceImages, isTrue);
    });
  });

  group('GeminiNativeProvider chat, thinking, tools & streaming', () {
    test('builds Gemini request body and parses SSE stream', () async {
      RequestOptions? capturedOptions;
      Map<String, dynamic>? capturedBody;

      final dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) {
        capturedOptions = options;
        capturedBody =
            jsonDecode(options.data as String) as Map<String, dynamic>;
        final sseEvents = [
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'role': 'model',
                  'parts': [
                    {'text': '先思考一下…', 'thought': true},
                  ],
                },
              },
            ],
          }),
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'role': 'model',
                  'parts': [
                    {'text': '你好，世界！'},
                    {
                      'functionCall': {
                        'name': 'web_search',
                        'args': {'query': 'Flutter Gemini'},
                      },
                      'thoughtSignature': 'sig_123',
                    },
                  ],
                },
                'finishReason': 'STOP',
                'groundingMetadata': {
                  'groundingChunks': [
                    {
                      'web': {
                        'uri': 'https://ai.google.dev',
                        'title': 'Google AI',
                      },
                    },
                  ],
                },
              },
            ],
            'usageMetadata': {
              'promptTokenCount': 12,
              'candidatesTokenCount': 8,
              'cachedContentTokenCount': 4,
              'thoughtsTokenCount': 5,
              'totalTokenCount': 25,
            },
          }),
        ];
        final payload =
            '${sseEvents.map((e) => 'data: $e\n\n').join()}data: [DONE]\n\n';
        return ResponseBody.fromString(
          payload,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        );
      });

      final provider = RoutingLlmProvider(
        geminiNative: GeminiNativeProvider(dio: dio),
      );

      final config = const LlmConfig(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        apiKey: 'gemini-test-key',
        model: 'gemini-2.5-flash',
      );
      expect(config.isGeminiNative, isTrue);

      final chunks = await provider
          .streamChat(
            config: config,
            thinking: true,
            reasoningEffort: ReasoningEffort.high,
            messages: const [
              LlmRequestMessage(
                role: MessageRole.system,
                content: '你是一个乐于助人的助手。',
              ),
              LlmRequestMessage(
                role: MessageRole.user,
                content: '请看这张图并搜索 Flutter Gemini',
                imageDataUrls: ['data:image/png;base64,aGVsbG8='],
              ),
            ],
            tools: const [
              ToolSpec(
                name: 'web_search',
                description: 'Search the web',
                parameters: {
                  'type': 'object',
                  'properties': {
                    'query': {'type': 'string'},
                  },
                  'additionalProperties': false,
                },
              ),
            ],
          )
          .toList();

      expect(
        capturedOptions!.uri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse',
      );
      expect(capturedOptions!.headers['x-goog-api-key'], 'gemini-test-key');
      expect(capturedOptions!.headers.containsKey('Authorization'), isFalse);

      expect(capturedBody!['systemInstruction'], {
        'parts': [
          {'text': '你是一个乐于助人的助手。'},
        ],
      });
      final contents = capturedBody!['contents'] as List<dynamic>;
      expect(contents, hasLength(1));
      expect(contents.first['role'], 'user');
      expect((contents.first['parts'] as List).length, 2);

      final declarations =
          ((capturedBody!['tools'] as List).first
                  as Map)['functionDeclarations']
              as List;
      final params = (declarations.first as Map)['parametersJsonSchema'] as Map;
      expect(params['additionalProperties'], isFalse);

      expect(capturedBody!['generationConfig'], {
        'thinkingConfig': {'includeThoughts': true, 'thinkingBudget': 8192},
      });

      expect(chunks, hasLength(2));
      expect(chunks[0].reasoningDelta, '先思考一下…');
      expect(chunks[1].contentDelta, '你好，世界！');
      expect(chunks[1].finishReason, 'tool_calls');
      expect(chunks[1].toolCalls, hasLength(1));
      expect(chunks[1].toolCalls!.first.name, 'web_search');
      expect(chunks[1].responseOutputItems, isNotNull);
      expect(chunks[1].citations, hasLength(1));
      expect(chunks[1].citations!.first.url, 'https://ai.google.dev');
      expect(chunks[1].usage!.inputTokens, 12);
      expect(chunks[1].usage!.outputTokens, 13);
      expect(chunks[1].usage!.cachedInputTokens, 4);
      expect(chunks[1].usage!.reasoningTokens, 5);
    });

    test(
      'OpenAiCompatibleProvider normalizes bare Gemini URL when OpenAI format is chosen',
      () async {
        RequestOptions? capturedOptions;
        final dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) {
          capturedOptions = options;
          return ResponseBody.fromString(
            'data: [DONE]\n\n',
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
          );
        });

        final provider = RoutingLlmProvider(
          chatCompletions: OpenAiCompatibleProvider(dio: dio),
        );
        final config = const LlmConfig(
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          apiKey: 'gemini-test-key',
          model: 'gemini-2.5-flash',
          apiFormat: LlmApiFormat.openAiCompatible,
        );
        expect(config.isGeminiNative, isFalse);

        await provider
            .streamChat(
              config: config,
              messages: const [
                LlmRequestMessage(role: MessageRole.user, content: 'hi'),
              ],
            )
            .toList();

        expect(
          capturedOptions!.uri.toString(),
          'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
        );
      },
    );
  });

  group('OpenAiCompatibleMediaProvider Gemini image generation', () {
    test(
      'uses :generateContent with responseModalities for gemini image models and reference images',
      () async {
        RequestOptions? capturedOptions;
        Map<String, dynamic>? capturedBody;

        final dio = Dio();
        dio.httpClientAdapter = _FakeHttpClientAdapter((options) {
          capturedOptions = options;
          capturedBody =
              jsonDecode(options.data as String) as Map<String, dynamic>;
          return ResponseBody.fromString(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': '为您生成了猫咪插画'},
                      {
                        'inlineData': {
                          'mimeType': 'image/png',
                          'data': 'aGVsbG8=',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });

        final mediaProvider = OpenAiCompatibleMediaProvider(dio: dio);
        final result = await mediaProvider.generateImage(
          config: const MediaApiConfig(
            baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
            model: 'gemini-2.5-flash-image',
          ),
          apiKey: 'gemini-test-key',
          prompt: '画一只戴帽子的猫',
          referenceImages: [
            ImageEditReference(
              bytes: Uint8List.fromList([1, 2, 3, 4]),
              mimeType: 'image/png',
              fileName: 'ref.png',
            ),
          ],
        );

        expect(
          capturedOptions!.uri.toString(),
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent',
        );
        expect(capturedBody!['generationConfig'], {
          'responseModalities': ['TEXT', 'IMAGE'],
          'imageConfig': {'aspectRatio': '1:1'},
        });
        final parts =
            ((capturedBody!['contents'] as List).first as Map)['parts'] as List;
        expect(parts, hasLength(2));
        expect(result.base64, 'aGVsbG8=');
        expect(result.mimeType, 'image/png');
        expect(result.revisedPrompt, '为您生成了猫咪插画');
      },
    );

    test('uses :predict for Imagen models on Gemini native endpoint', () async {
      RequestOptions? capturedOptions;
      Map<String, dynamic>? capturedBody;

      final dio = Dio();
      dio.httpClientAdapter = _FakeHttpClientAdapter((options) {
        capturedOptions = options;
        capturedBody =
            jsonDecode(options.data as String) as Map<String, dynamic>;
        return ResponseBody.fromString(
          jsonEncode({
            'predictions': [
              {'bytesBase64Encoded': 'aGVsbG8=', 'mimeType': 'image/jpeg'},
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });

      final mediaProvider = OpenAiCompatibleMediaProvider(dio: dio);
      final result = await mediaProvider.generateImage(
        config: const MediaApiConfig(
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          model: 'imagen-3.0-generate-002',
          imageSize: '16:9',
        ),
        apiKey: 'gemini-test-key',
        prompt: 'A futuristic city',
      );

      expect(
        capturedOptions!.uri.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/imagen-3.0-generate-002:predict',
      );
      expect(capturedBody!['parameters'], {
        'sampleCount': 1,
        'aspectRatio': '16:9',
      });
      expect(result.base64, 'aGVsbG8=');
      expect(result.mimeType, 'image/jpeg');
    });
  });
}
