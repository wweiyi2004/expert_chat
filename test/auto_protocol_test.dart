import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/anthropic_messages_provider.dart';
import 'package:expert_chat/domain/llm/gemini_native_provider.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_connection_tester.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/llm/responses_api_provider.dart';
import 'package:expert_chat/domain/llm/routing_llm_provider.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handle);
  final FutureOr<ResponseBody> Function(RequestOptions) handle;
  final calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return handle(options);
  }

  @override
  void close({bool force = false}) {}
}

const _config = LlmConfig(
  baseUrl: 'https://relay.invalid/v1',
  apiKey: 'synthetic',
  model: 'claude-sonnet-4-6',
);
const _messages = [LlmRequestMessage(role: MessageRole.user, content: 'hello')];
ResponseBody _error(int code, [String message = 'Unknown endpoint']) =>
    ResponseBody.fromString(
      jsonEncode({
        'error': {'message': message},
      }),
      code,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
ResponseBody _sse(String text) => ResponseBody.fromString(
  text,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);
const _chat =
    'data: {"choices":[{"delta":{"content":"chat"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
const _responses =
    'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"responses"}\n\nevent: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","output":[]}}\n\n';
const _gemini =
    'data: {"candidates":[{"content":{"parts":[{"text":"gemini"}]},"finishReason":"STOP"}]}\n\n';
String _event(Map<String, dynamic> data) =>
    'event: ${data['type']}\ndata: ${jsonEncode(data)}\n\n';
final _anthropic = [
  {
    'type': 'message_start',
    'message': {
      'usage': {'input_tokens': 5, 'output_tokens': 1},
    },
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': 'anthropic'},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
    'usage': {'output_tokens': 2},
  },
  {'type': 'message_stop'},
].map(_event).join();

RoutingLlmProvider _router(_Adapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return RoutingLlmProvider(
    chatCompletions: OpenAiCompatibleProvider(dio: dio),
    responses: ResponsesApiProvider(dio: dio),
    geminiNative: GeminiNativeProvider(dio: dio),
    anthropic: AnthropicMessagesProvider(dio: dio),
  );
}

void main() {
  test(
    'Gemini discovery tries v1beta without dropping a relay mount prefix',
    () async {
      final adapter = _Adapter(
        (o) =>
            o.uri.path ==
                '/tenant/v1beta/models/gemini-custom:streamGenerateContent'
            ? _sse(_gemini)
            : _error(404),
      );
      final router = _router(adapter);
      final config = _config.copyWith(
        baseUrl: 'https://relay.invalid/tenant/v1',
        model: 'gemini-custom',
      );
      await router.streamChat(config: config, messages: _messages).toList();
      expect(adapter.calls, hasLength(5));
      expect(
        adapter.calls.every((r) => r.uri.path.startsWith('/tenant/')),
        true,
      );
      expect(router.detectedFormat(config), LlmApiFormat.geminiNative);
      await router.streamChat(config: config, messages: _messages).toList();
      expect(adapter.calls, hasLength(6));
    },
  );
  test('connection check cancellation retains the discovered route', () async {
    final adapter = _Adapter(
      (o) => o.uri.path == '/v1/messages' ? _sse(_anthropic) : _error(404),
    );
    final router = _router(adapter);
    await ModelConnectionTester(
      router,
    ).check(_config, cancelToken: CancelToken());
    expect(router.detectedFormat(_config), LlmApiFormat.anthropicMessages);
    await router.streamChat(config: _config, messages: _messages).toList();
    expect(adapter.calls, hasLength(4));
  });

  test('structured model-not-found code does not trigger detection', () async {
    final adapter = _Adapter(
      (_) => ResponseBody.fromString(
        '{"error":{"message":"Not found","code":"model_not_found"}}',
        404,
      ),
    );
    await expectLater(
      _router(
        adapter,
      ).streamChat(config: _config, messages: _messages).toList(),
      throwsA(isA<LlmHttpException>()),
    );
    expect(adapter.calls, hasLength(1));
  });

  test('network timeouts do not trigger detection', () async {
    final adapter = _Adapter(
      (o) => throw DioException(
        requestOptions: o,
        type: DioExceptionType.connectionTimeout,
      ),
    );
    await expectLater(
      _router(
        adapter,
      ).streamChat(config: _config, messages: _messages).toList(),
      throwsA(isA<LlmHttpException>()),
    );
    expect(adapter.calls, hasLength(1));
  });
  test(
    'unknown relay tries protocols and caches the successful Messages route',
    () async {
      final adapter = _Adapter(
        (o) => o.uri.path == '/v1/messages' ? _sse(_anthropic) : _error(404),
      );
      final router = _router(adapter);
      final chunks = await router
          .streamChat(config: _config, messages: _messages)
          .toList();
      expect(
        chunks.map((c) => c.contentDelta).whereType<String>().join(),
        'anthropic',
      );
      expect(adapter.calls.map((o) => o.uri.path), [
        '/v1/chat/completions',
        '/v1/responses',
        '/v1/messages',
      ]);
      expect(adapter.calls.last.headers['anthropic-version'], '2023-06-01');
      expect(adapter.calls.last.headers['x-api-key'], 'synthetic');
      expect(router.detectedFormat(_config), LlmApiFormat.anthropicMessages);
      await router.streamChat(config: _config, messages: _messages).toList();
      expect(adapter.calls, hasLength(4));
      expect(adapter.calls.last.uri.path, '/v1/messages');
    },
  );

  test('full Responses URL chooses Responses without hosted search', () async {
    final adapter = _Adapter((_) => _sse(_responses));
    final router = _router(adapter);
    await router
        .streamChat(
          config: _config.copyWith(
            baseUrl: 'https://relay.invalid/tenant/v1/responses?route=a',
          ),
          messages: _messages,
          thinking: false,
        )
        .toList();
    final request = adapter.calls.single;
    expect(
      request.uri.toString(),
      'https://relay.invalid/tenant/v1/responses?route=a',
    );
    final body = jsonDecode(request.data as String) as Map;
    expect(body['input'], isNotEmpty);
    expect(body.containsKey('tools'), false);
    expect(
      body.containsKey('reasoning'),
      false,
      reason: 'Do not force reasoning parameters on an unrelated model',
    );
  });

  test('root URL also tries /v1 while preserving origin and query', () async {
    final adapter = _Adapter(
      (o) => o.uri.path == '/v1/chat/completions' ? _sse(_chat) : _error(404),
    );
    await _router(adapter)
        .streamChat(
          config: _config.copyWith(baseUrl: 'https://relay.invalid?route=a'),
          messages: _messages,
        )
        .toList();
    expect(adapter.calls.map((o) => o.uri.path), [
      '/chat/completions',
      '/v1/chat/completions',
    ]);
    expect(
      adapter.calls.every(
        (o) => o.uri.host == 'relay.invalid' && o.uri.query == 'route=a',
      ),
      true,
    );
  });

  test(
    'unknown relay can discover native Gemini after other schemas reject',
    () async {
      final adapter = _Adapter(
        (o) => o.uri.path.endsWith(':streamGenerateContent')
            ? _sse(_gemini)
            : _error(405),
      );
      final router = _router(adapter);
      final c = _config.copyWith(model: 'gemini-custom');
      final chunks = await router
          .streamChat(config: c, messages: _messages)
          .toList();
      expect(chunks.first.contentDelta, 'gemini');
      expect(adapter.calls, hasLength(4));
      expect(router.detectedFormat(c), LlmApiFormat.geminiNative);
      expect(adapter.calls.last.headers['x-goog-api-key'], 'synthetic');
    },
  );

  test('schema rejection can advance to Responses', () async {
    final adapter = _Adapter(
      (o) => o.uri.path.endsWith('/responses')
          ? _sse(_responses)
          : _error(400, "Missing required parameter: 'input'"),
    );
    await _router(
      adapter,
    ).streamChat(config: _config, messages: _messages).toList();
    expect(adapter.calls, hasLength(2));
  });

  for (final (code, message) in [
    (401, 'bad key'),
    (402, 'no balance'),
    (403, 'forbidden'),
    (429, 'rate limited'),
    (500, 'server error'),
    (400, 'maximum context length exceeded'),
    (400, 'thinking.type.enabled is not supported'),
    (404, 'The model does not exist'),
  ]) {
    test('HTTP $code $message does not cause protocol replay', () async {
      final adapter = _Adapter((_) => _error(code, message));
      await expectLater(
        _router(
          adapter,
        ).streamChat(config: _config, messages: _messages).toList(),
        throwsA(isA<LlmHttpException>()),
      );
      expect(adapter.calls, hasLength(1));
    });
  }

  test('manual protocol selection never falls back', () async {
    final adapter = _Adapter((_) => _error(404));
    await expectLater(
      _router(adapter)
          .streamChat(
            config: _config.copyWith(apiFormat: LlmApiFormat.anthropicMessages),
            messages: _messages,
          )
          .toList(),
      throwsA(isA<LlmHttpException>()),
    );
    expect(adapter.calls.single.uri.path, '/v1/messages');
  });

  test('all failures stop after the bounded candidate set', () async {
    final adapter = _Adapter((_) => _error(404));
    await expectLater(
      _router(adapter)
          .streamChat(
            config: _config.copyWith(baseUrl: 'https://relay.invalid'),
            messages: _messages,
          )
          .toList(),
      throwsA(predicate((e) => e.toString().contains('已尝试 7 个接口'))),
    );
    expect(adapter.calls, hasLength(7));
    expect(adapter.calls.map((o) => o.uri.toString()).toSet(), hasLength(7));
  });

  test('cache is isolated by credential, model and endpoint', () async {
    final adapter = _Adapter(
      (o) => o.uri.path.endsWith('/messages') ? _sse(_anthropic) : _error(404),
    );
    final router = _router(adapter);
    for (final config in [
      _config,
      _config.copyWith(apiKey: 'another-synthetic'),
      _config.copyWith(model: 'another-model'),
      _config.copyWith(baseUrl: 'https://other.invalid/v1'),
    ]) {
      final before = adapter.calls.length;
      await router.streamChat(config: config, messages: _messages).toList();
      expect(adapter.calls.length - before, 3);
    }
  });

  test('a cached endpoint rejection triggers fresh discovery', () async {
    var messagesAvailable = true;
    final adapter = _Adapter(
      (o) => messagesAvailable
          ? o.uri.path.endsWith('/messages')
                ? _sse(_anthropic)
                : _error(404)
          : o.uri.path.endsWith('/chat/completions')
          ? _sse(_chat)
          : _error(404),
    );
    final router = _router(adapter);
    await router.streamChat(config: _config, messages: _messages).toList();
    messagesAvailable = false;
    await router.streamChat(config: _config, messages: _messages).toList();
    expect(adapter.calls.skip(3).map((o) => o.uri.path), [
      '/v1/messages',
      '/v1/chat/completions',
    ]);
    expect(router.detectedFormat(_config), LlmApiFormat.openAiCompatible);
  });

  test(
    'native tool continuation remains pinned even without a cache',
    () async {
      final adapter = _Adapter((_) => _error(404));
      await expectLater(
        _router(adapter)
            .streamChat(
              config: _config,
              messages: [
                ..._messages,
                const LlmRequestMessage(
                  role: MessageRole.assistant,
                  content: '',
                  responseOutputItems: [
                    {
                      'type': 'tool_use',
                      'id': 't1',
                      'name': 'test',
                      'input': {},
                    },
                  ],
                ),
                const LlmRequestMessage(
                  role: MessageRole.tool,
                  content: 'result',
                  toolCallId: 't1',
                ),
              ],
            )
            .toList(),
        throwsA(isA<LlmHttpException>()),
      );
      expect(adapter.calls.single.uri.path, '/v1/messages');
    },
  );

  test('partial output is never replayed after a later HTTP error', () async {
    final adapter = _Adapter((o) {
      Stream<Uint8List> stream() async* {
        yield Uint8List.fromList(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n',
          ),
        );
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: o, statusCode: 404),
        );
      }

      return ResponseBody(stream(), 200);
    });
    final seen = <String>[];
    await expectLater(
      _router(adapter).streamChat(config: _config, messages: _messages).forEach(
        (c) {
          if (c.contentDelta != null) seen.add(c.contentDelta!);
        },
      ),
      throwsA(isA<LlmHttpException>()),
    );
    expect(seen, ['partial']);
    expect(adapter.calls, hasLength(1));
  });

  test(
    'accepted but unrecognized response does not resubmit generation',
    () async {
      final adapter = _Adapter((_) => _sse('data: {"unrecognized":true}\n\n'));
      await expectLater(
        _router(
          adapter,
        ).streamChat(config: _config, messages: _messages).toList(),
        throwsFormatException,
      );
      expect(adapter.calls, hasLength(1));
    },
  );

  test('cancel during rejection stops discovery immediately', () async {
    final token = CancelToken();
    final adapter = _Adapter((_) {
      token.cancel('stop');
      return _error(404);
    });
    await _router(adapter)
        .streamChat(config: _config, messages: _messages, cancelToken: token)
        .toList();
    expect(adapter.calls, hasLength(1));
  });

  test('new manual formats survive profile serialization', () {
    for (final format in [
      LlmApiFormat.openAiResponses,
      LlmApiFormat.anthropicMessages,
    ]) {
      final p = ProviderProfile(
        id: 'p',
        name: 'p',
        baseUrl: _config.baseUrl,
        chatModel: _config.model,
        reasonerModel: _config.model,
        models: [_config.model],
        apiFormat: format,
      );
      expect(ProviderProfile.fromJson(p.toJson()).apiFormat, format);
    }
  });
}
