import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/tool_image_context.dart';
import 'package:expert_chat/domain/llm/gemini_native_provider.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = LlmConfig(
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
  apiKey: 'test-key',
  model: 'gemini-3-flash-preview',
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions, Future<void>?) respond;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return respond(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _candidate(
  List<Map<String, dynamic>> parts, {
  String? finish,
}) => {
  'candidates': [
    {
      'index': 0,
      'content': {'role': 'model', 'parts': parts},
      'finishReason': ?finish,
    },
  ],
};

String _sse(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';

GeminiNativeProvider _provider(String sse, {bool fragmentBytes = false}) {
  final adapter = _Adapter((_, _) {
    final bytes = utf8.encode(sse);
    return ResponseBody(
      Stream.fromIterable(
        fragmentBytes
            ? [
                for (final byte in bytes) Uint8List.fromList([byte]),
              ]
            : [Uint8List.fromList(bytes)],
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  });
  return GeminiNativeProvider(dio: Dio()..httpClientAdapter = adapter);
}

Stream<ChatChunk> _stream(
  GeminiNativeProvider provider, {
  CancelToken? cancelToken,
}) => provider.streamChat(
  config: _config,
  messages: const [LlmRequestMessage(role: MessageRole.user, content: 'hello')],
  cancelToken: cancelToken,
);

void main() {
  final screenshot = Attachment(
    name: 'screen.png',
    mimeType: 'image/png',
    imageBase64: 'YWJj',
  );
  const imageCalls = [
    ToolCall(index: 0, id: 'first', name: 'capture', argumentsJson: '{}'),
    ToolCall(index: 1, id: 'last', name: 'click', argumentsJson: '{}'),
  ];
  const imageCallParts = [
    {
      'functionCall': {
        'id': 'first',
        'name': 'capture',
        'args': <String, dynamic>{},
      },
      'thoughtSignature': 'screen-signature',
    },
    {
      'functionCall': {
        'id': 'last',
        'name': 'click',
        'args': <String, dynamic>{},
      },
    },
  ];
  List<LlmRequestMessage> imageHistory() => [
    const LlmRequestMessage(
      role: MessageRole.user,
      content: 'Operate this screen',
    ),
    const LlmRequestMessage(
      role: MessageRole.assistant,
      content: '',
      toolCalls: imageCalls,
      responseOutputItems: imageCallParts,
    ),
    const LlmRequestMessage(
      role: MessageRole.tool,
      content: 'captured',
      toolCallId: 'first',
    ),
    const LlmRequestMessage(
      role: MessageRole.tool,
      content: 'clicked without image',
      toolCallId: 'last',
    ),
    ToolImageContext.observation(screenshot, callId: 'first'),
  ];

  test(
    'Gemini 3 screenshot belongs to its source call, not the last parallel result',
    () {
      final body = GeminiNativeProvider.buildRequestBody(
        config: _config,
        messages: imageHistory(),
      );
      final contents = body['contents'] as List;
      expect(contents[1]['parts'], imageCallParts);
      final parts = contents.last['parts'] as List;
      expect(parts, hasLength(2));
      expect(parts.every((p) => p.containsKey('functionResponse')), isTrue);
      final first = parts.first['functionResponse'] as Map;
      final last = parts.last['functionResponse'] as Map;
      expect(first['id'], 'first');
      expect(first['parts'], [
        {
          'inlineData': {'mimeType': 'image/png', 'data': 'YWJj'},
        },
      ]);
      expect(first['response']['result'], contains('属于工具数据'));
      expect(last['id'], 'last');
      expect(last.containsKey('parts'), isFalse);
      expect(last['response']['result'], 'clicked without image');
    },
  );

  test(
    'retired screenshot notes remain inside their original function response',
    () {
      final history = imageHistory();
      ToolImageContext.append(history, [
        const LlmRequestMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'fresh',
              name: 'capture',
              argumentsJson: '{}',
            ),
          ],
          responseOutputItems: [
            {
              'functionCall': {
                'id': 'fresh',
                'name': 'capture',
                'args': <String, dynamic>{},
              },
              'thoughtSignature': 'fresh-signature',
            },
          ],
        ),
        const LlmRequestMessage(
          role: MessageRole.tool,
          content: 'fresh capture',
          toolCallId: 'fresh',
        ),
        ToolImageContext.observation(screenshot, callId: 'fresh'),
      ]);
      final body = GeminiNativeProvider.buildRequestBody(
        config: _config,
        messages: history,
      );
      final contents = body['contents'] as List;
      final userTexts = [
        for (final c in contents)
          if (c['role'] == 'user')
            for (final p in c['parts'] as List)
              if (p.containsKey('text')) p['text'],
      ];
      expect(userTexts, ['Operate this screen']);
      final oldResponse = contents[2]['parts'][0]['functionResponse'] as Map;
      expect(oldResponse['response']['result'], contains('旧截图已移出'));
      expect(oldResponse.containsKey('parts'), isFalse);
      expect(contents[3]['parts'][0]['thoughtSignature'], 'fresh-signature');
      expect(
        contents[4]['parts'][0]['functionResponse']['parts'],
        hasLength(1),
      );
    },
  );

  test(
    'orphan or previous-batch screenshot is rejected instead of guessing a result',
    () {
      for (final observation in [
        ToolImageContext.observation(screenshot),
        ToolImageContext.observation(screenshot, callId: 'missing'),
      ]) {
        expect(
          () => GeminiNativeProvider.buildRequestBody(
            config: _config,
            messages: [...imageHistory().take(4), observation],
          ),
          throwsStateError,
        );
      }
      expect(
        () => GeminiNativeProvider.buildRequestBody(
          config: _config,
          messages: [
            ...imageHistory().take(4),
            const LlmRequestMessage(
              role: MessageRole.assistant,
              content: 'new step',
            ),
            ToolImageContext.observation(screenshot, callId: 'first'),
          ],
        ),
        throwsStateError,
      );
    },
  );

  test('Gemini 2.5 keeps its existing top-level image observation format', () {
    final body = GeminiNativeProvider.buildRequestBody(
      config: _config.copyWith(model: 'gemini-2.5-flash'),
      messages: imageHistory(),
    );
    final parts = (body['contents'] as List).last['parts'] as List;
    expect(parts[0]['functionResponse'].containsKey('parts'), isFalse);
    expect(parts[2]['text'], contains('属于工具数据'));
    expect(parts[3], {
      'inlineData': {'mimeType': 'image/png', 'data': 'YWJj'},
    });
  });

  test(
    'remote PNG and signed image URLs do not receive a guessed MIME type',
    () {
      const remoteUrls = [
        'https://example.com/photo.png',
        'https://example.com/signed?id=123&signature=opaque',
      ];
      final body = GeminiNativeProvider.buildRequestBody(
        config: _config,
        messages: const [
          LlmRequestMessage(
            role: MessageRole.user,
            content: '看图',
            imageDataUrls: [...remoteUrls, 'data:image/webp;base64,YWJj'],
          ),
        ],
      );
      final parts = (body['contents'] as List).single['parts'] as List;
      expect(parts[1], {
        'fileData': {'fileUri': remoteUrls[0]},
      });
      expect(parts[2], {
        'fileData': {'fileUri': remoteUrls[1]},
      });
      expect(parts[3], {
        'inlineData': {'mimeType': 'image/webp', 'data': 'YWJj'},
      });
    },
  );

  test(
    'fragmented SSE preserves UTF-8, signed empty parts and trailing usage',
    () async {
      final originalParts = <Map<String, dynamic>>[
        {'text': '先分析', 'thought': true},
        {'text': '答案🌍'},
        {'text': '', 'thoughtSignature': 'opaque-signature'},
      ];
      final chunks = await _stream(
        _provider(
          ': heartbeat\n\n'
          '${_sse(_candidate([originalParts[0]]))}'
          '${_sse(_candidate([originalParts[1]]))}'
          '${_sse(_candidate([originalParts[2]], finish: 'STOP'))}'
          '${_sse({
            'usageMetadata': {'promptTokenCount': 15, 'candidatesTokenCount': 7, 'thoughtsTokenCount': 4, 'cachedContentTokenCount': 3, 'totalTokenCount': 26},
          })}',
          fragmentBytes: true,
        ),
      ).toList();
      expect(
        chunks.map((c) => c.reasoningDelta).whereType<String>().join(),
        '先分析',
      );
      expect(
        chunks.map((c) => c.contentDelta).whereType<String>().join(),
        '答案🌍',
      );
      expect(chunks[2].finishReason, 'stop');
      expect(chunks[2].responseOutputItems, originalParts);
      expect(chunks.last.usage!.inputTokens, 15);
      expect(chunks.last.usage!.outputTokens, 11);
      expect(chunks.last.usage!.reasoningTokens, 4);
      expect(chunks.last.usage!.cachedInputTokens, 3);
      final request = GeminiNativeProvider.buildRequestBody(
        config: _config,
        messages: [
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: '答案🌍',
            reasoningContent: '先分析',
            responseOutputItems: chunks[2].responseOutputItems!,
          ),
          const LlmRequestMessage(role: MessageRole.user, content: '继续'),
        ],
      );
      expect((request['contents'] as List).first['parts'], originalParts);
    },
  );

  test(
    'multiline SSE event and terminal event without trailing newline parse',
    () async {
      final chunks = await _stream(
        _provider(
          'data: {"candidates":[\n'
          'data: {"content":{"parts":[{"text":"hello"}]},"finishReason":"STOP"}\n'
          'data: ]}',
        ),
      ).toList();
      expect(chunks.single.contentDelta, 'hello');
      expect(chunks.single.finishReason, 'stop');
    },
  );

  for (final withIds in [true, false]) {
    test(
      'parallel calls round-trip exact signed parts and ${withIds ? 'wire' : 'absent'} ids',
      () async {
        final parts = <Map<String, dynamic>>[
          {
            'functionCall': {
              'name': 'lookup',
              'args': {'city': 'Paris'},
              if (withIds) 'id': 'provider-first',
            },
            'thoughtSignature': 'sig-first',
          },
          {
            'functionCall': {
              'name': 'lookup',
              'args': {'city': 'London'},
              if (withIds) 'id': 'provider-second',
            },
          },
        ];
        final chunks = await _stream(
          _provider(
            '${_sse(_candidate(parts))}${_sse(_candidate([], finish: 'STOP'))}',
          ),
        ).toList();
        expect(chunks.first.toolCalls, isNull);
        final result = chunks.last;
        expect(result.finishReason, 'tool_calls');
        expect(result.toolCalls, hasLength(2));
        expect(result.responseOutputItems, parts);
        final request = GeminiNativeProvider.buildRequestBody(
          config: _config,
          messages: [
            LlmRequestMessage(
              role: MessageRole.assistant,
              content: '',
              toolCalls: result.toolCalls!,
              responseOutputItems: result.responseOutputItems!,
            ),
            for (final call in result.toolCalls!)
              LlmRequestMessage(
                role: MessageRole.tool,
                content: 'result-${call.index}',
                toolCallId: call.id,
              ),
          ],
        );
        final contents = request['contents'] as List;
        expect(contents, hasLength(2));
        expect(contents.first['parts'], parts);
        final responses = contents.last['parts'] as List;
        for (var i = 0; i < 2; i++) {
          final response = responses[i]['functionResponse'] as Map;
          expect(response['name'], 'lookup');
          expect(response['response'], {'result': 'result-$i'});
          if (withIds) {
            expect(
              response['id'],
              i == 0 ? 'provider-first' : 'provider-second',
            );
          } else {
            expect(response.containsKey('id'), isFalse);
          }
        }
      },
    );
  }

  for (final entry in {
    'MAX_TOKENS': 'length',
    'SAFETY': 'content_filter',
    'RECITATION': 'content_filter',
    'PROHIBITED_CONTENT': 'content_filter',
  }.entries) {
    test(
      '${entry.key} remains incomplete even after a function call',
      () async {
        final chunks = await _stream(
          _provider(
            _sse(
              _candidate([
                {
                  'functionCall': {
                    'name': 'write_file',
                    'args': {'path': 'out.txt'},
                  },
                },
              ], finish: entry.key),
            ),
          ),
        ).toList();
        expect(chunks.last.finishReason, entry.value);
        expect(chunks.expand((c) => c.toolCalls ?? <ToolCall>[]), isEmpty);
      },
    );
  }

  for (final reason in [
    'MALFORMED_FUNCTION_CALL',
    'UNEXPECTED_TOOL_CALL',
    'OTHER',
  ]) {
    test(
      '$reason is a stream error instead of successful tool execution',
      () async {
        await expectLater(
          _stream(
            _provider(
              _sse(
                _candidate([
                  {
                    'functionCall': {'name': 'write_file', 'args': {}},
                  },
                ], finish: reason),
              ),
            ),
          ).toList(),
          throwsA(predicate((e) => e.toString().contains(reason))),
        );
      },
    );
  }

  test(
    'EOF without candidate finish preserves received content then reports interruption',
    () async {
      await expectLater(
        _stream(
          _provider(
            _sse(
              _candidate([
                {'text': 'partial'},
              ]),
            ),
          ),
        ),
        emitsInOrder([
          isA<ChatChunk>().having((c) => c.contentDelta, 'content', 'partial'),
          emitsError(predicate((e) => e.toString().contains('完成前中断'))),
          emitsDone,
        ]),
      );
    },
  );

  test('provider error event and blocked prompt are surfaced', () async {
    for (final event in [
      {
        'error': {'code': 429, 'message': 'quota exhausted'},
      },
      {
        'promptFeedback': {'blockReason': 'SAFETY'},
      },
    ]) {
      await expectLater(
        _stream(_provider(_sse(event))).toList(),
        throwsA(isA<Exception>()),
      );
    }
  });

  test('malformed complete SSE event is not silently skipped', () async {
    await expectLater(
      _stream(_provider('data: {invalid}\n\n')).toList(),
      throwsFormatException,
    );
  });

  test('already-cancelled request never reaches HTTP adapter', () async {
    final adapter = _Adapter((_, _) => throw StateError('must not call'));
    final token = CancelToken()..cancel('stopped');
    expect(
      await _stream(
        GeminiNativeProvider(dio: Dio()..httpClientAdapter = adapter),
        cancelToken: token,
      ).toList(),
      isEmpty,
    );
    expect(adapter.requests, 0);
  });

  test(
    'cancellation while waiting for headers ends quietly and cancels HTTP',
    () async {
      final entered = Completer<void>();
      final cancelled = Completer<void>();
      final adapter = _Adapter((options, cancelFuture) async {
        entered.complete();
        await cancelFuture;
        cancelled.complete();
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        );
      });
      final token = CancelToken();
      final done = _stream(
        GeminiNativeProvider(dio: Dio()..httpClientAdapter = adapter),
        cancelToken: token,
      ).toList();
      await entered.future;
      token.cancel('stopped');
      expect(await done.timeout(const Duration(seconds: 2)), isEmpty);
      await cancelled.future.timeout(const Duration(seconds: 2));
    },
  );

  test(
    'mid-stream cancellation stops HTTP without reporting truncated output',
    () async {
      final source = StreamController<Uint8List>();
      final bodyCancelled = Completer<void>();
      source.onCancel = () {
        bodyCancelled.complete();
      };
      final adapter = _Adapter(
        (_, _) => ResponseBody(
          source.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['text/event-stream'],
          },
        ),
      );
      final token = CancelToken();
      final received = Completer<void>();
      final chunks = <ChatChunk>[];
      final done =
          _stream(
            GeminiNativeProvider(dio: Dio()..httpClientAdapter = adapter),
            cancelToken: token,
          ).forEach((chunk) {
            chunks.add(chunk);
            if (!received.isCompleted) received.complete();
          });
      source.add(
        Uint8List.fromList(
          utf8.encode(
            _sse(
              _candidate([
                {'text': 'partial'},
              ]),
            ),
          ),
        ),
      );
      await received.future;
      token.cancel('stopped');
      await done.timeout(const Duration(seconds: 2));
      await bodyCancelled.future.timeout(const Duration(seconds: 2));
      await source.close();
      expect(chunks.single.contentDelta, 'partial');
    },
  );

  test(
    'tool JSON Schema is sent verbatim including properties named like schema keywords',
    () {
      final schema = <String, dynamic>{
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'additionalProperties': {'type': 'string'},
          r'$schema': {'type': 'string'},
          'nested': {
            'type': 'object',
            'additionalProperties': {'type': 'integer'},
          },
        },
      };
      final before = jsonEncode(schema);
      final request = GeminiNativeProvider.buildRequestBody(
        config: _config,
        messages: const [],
        tools: [
          ToolSpec(name: 'test', description: 'test', parameters: schema),
        ],
      );
      final declaration =
          (request['tools'] as List).single['functionDeclarations'].single
              as Map;
      expect(declaration['parametersJsonSchema'], schema);
      expect(declaration.containsKey('parameters'), isFalse);
      expect(jsonEncode(schema), before);
    },
  );

  for (final scenario
      in <
        ({
          String model,
          bool thinking,
          ReasoningEffort effort,
          Map<String, dynamic> expected,
        })
      >[
        (
          model: 'gemini-2.5-flash',
          thinking: false,
          effort: ReasoningEffort.high,
          expected: {'thinkingBudget': 0},
        ),
        (
          model: 'gemini-2.5-pro',
          thinking: false,
          effort: ReasoningEffort.high,
          expected: {'includeThoughts': false},
        ),
        (
          model: 'gemini-2.5-flash',
          thinking: true,
          effort: ReasoningEffort.max,
          expected: {'includeThoughts': true, 'thinkingBudget': 24576},
        ),
        (
          model: 'gemini-3-flash-preview',
          thinking: false,
          effort: ReasoningEffort.high,
          expected: {'includeThoughts': false, 'thinkingLevel': 'minimal'},
        ),
        (
          model: 'gemini-3-pro-preview',
          thinking: false,
          effort: ReasoningEffort.high,
          expected: {'includeThoughts': false, 'thinkingLevel': 'low'},
        ),
        (
          model: 'gemini-3.8-flash',
          thinking: false,
          effort: ReasoningEffort.high,
          expected: {'includeThoughts': false, 'thinkingLevel': 'low'},
        ),
        (
          model: 'models/gemini-3.1-pro-preview',
          thinking: true,
          effort: ReasoningEffort.low,
          expected: {'includeThoughts': true, 'thinkingLevel': 'low'},
        ),
        (
          model: 'gemini-3-flash-preview',
          thinking: true,
          effort: ReasoningEffort.max,
          expected: {'includeThoughts': true, 'thinkingLevel': 'high'},
        ),
      ]) {
    test(
      '${scenario.model} thinking=${scenario.thinking} uses its native control',
      () {
        final request = GeminiNativeProvider.buildRequestBody(
          config: _config.copyWith(model: scenario.model),
          messages: const [],
          thinking: scenario.thinking,
          reasoningEffort: scenario.effort,
        );
        expect(
          (request['generationConfig'] as Map)['thinkingConfig'],
          scenario.expected,
        );
      },
    );
  }

  test(
    'function response without its call fails locally instead of inventing a function name',
    () {
      expect(
        () => GeminiNativeProvider.buildRequestBody(
          config: _config,
          messages: const [
            LlmRequestMessage(
              role: MessageRole.tool,
              content: 'result',
              toolCallId: 'missing',
            ),
          ],
        ),
        throwsStateError,
      );
    },
  );
}
