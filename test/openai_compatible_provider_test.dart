import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Grok 4.3 disables reasoning effort in normal mode', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.x.ai/v1',
            apiKey: 'xai-test',
            model: 'grok-4.3',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hello'),
          ],
          thinking: false,
        )
        .toList();

    expect(adapter.body['reasoning_effort'], 'none');
  });

  test('Grok 4.5 requests high effort and parses reasoning deltas', () async {
    final adapter = _RecordingAdapter(
      sse: '''
data: {"choices":[{"delta":{"reasoning":"thinking"},"finish_reason":null}]}
data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}
data: [DONE]
''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    final chunks = await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.x.ai/v1',
            apiKey: 'xai-test',
            model: 'grok-4.5',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hello'),
          ],
          thinking: true,
        )
        .toList();

    expect(adapter.body['reasoning_effort'], 'high');
    expect(chunks.map((c) => c.reasoningDelta).whereType<String>(), [
      'thinking',
    ]);
    expect(chunks.map((c) => c.contentDelta).whereType<String>(), ['answer']);
  });

  test(
    'DeepSeek V4 sends thinking + reasoning_effort when deep-think is on',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = OpenAiCompatibleProvider(dio: dio);

      await provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.deepseek.com',
              apiKey: 'k',
              model: 'deepseek-v4-pro',
            ),
            messages: const [
              LlmRequestMessage(role: MessageRole.user, content: 'hello'),
            ],
            thinking: true,
          )
          .toList();

      expect(adapter.body['thinking'], {'type': 'enabled'});
      expect(adapter.body['reasoning_effort'], 'high');
    },
  );

  test(
    'DeepSeek V4 disables thinking without sending reasoning_effort none',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = OpenAiCompatibleProvider(dio: dio);

      await provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.deepseek.com',
              apiKey: 'k',
              model: 'deepseek-v4-flash',
            ),
            messages: const [
              LlmRequestMessage(role: MessageRole.user, content: 'hello'),
            ],
            thinking: false,
          )
          .toList();

      expect(adapter.body['thinking'], {'type': 'disabled'});
      expect(adapter.body, isNot(contains('reasoning_effort')));
    },
  );

  test('non-xAI models do not receive reasoning_effort', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'openai-test',
            model: 'gpt-4o',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hello'),
          ],
          thinking: false,
        )
        .toList();

    expect(adapter.body, isNot(contains('reasoning_effort')));
  });

  test('requests and parses streamed token usage', () async {
    final adapter = _RecordingAdapter(
      sse: '''
data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}
data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30,"total_tokens":150,"prompt_tokens_details":{"cached_tokens":80},"completion_tokens_details":{"reasoning_tokens":12}}}
data: [DONE]
''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    final chunks = await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'openai-test',
            model: 'gpt-4o',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hello'),
          ],
        )
        .toList();

    expect(adapter.body['stream_options'], {'include_usage': true});
    final usage = chunks
        .map((chunk) => chunk.usage)
        .whereType<LlmUsage>()
        .single;
    expect(usage.inputTokens, 120);
    expect(usage.outputTokens, 30);
    expect(usage.cachedInputTokens, 80);
    expect(usage.reasoningTokens, 12);
  });

  test('times out when response headers never arrive', () async {
    final dio = Dio()..httpClientAdapter = _HangingAdapter();
    final provider = OpenAiCompatibleProvider(
      dio: dio,
      responseHeaderTimeout: const Duration(milliseconds: 100),
    );

    await expectLater(
      provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.example.com/v1',
              apiKey: 'test-key',
              model: 'test-model',
            ),
            messages: const [
              LlmRequestMessage(role: MessageRole.user, content: 'hello'),
            ],
          )
          .toList()
          .timeout(const Duration(seconds: 5)),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('响应超时'),
        ),
      ),
    );
  });

  test(
    'joins wrapped data: lines into one event (gateway line folding)',
    () async {
      // A gateway folds a long JSON payload at a token boundary; the fragments
      // must be joined with '\n' per the SSE spec and parsed once.
      final adapter = _RecordingAdapter(
        sse: '''
data: {"choices":[{"delta":{"content":"hello"}
data: ,"finish_reason":"stop"}]}

data: [DONE] done

''',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = OpenAiCompatibleProvider(dio: dio);

      final chunks = await provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.deepseek.com',
              apiKey: 'deepseek-test',
              model: 'deepseek-v4-pro',
            ),
            messages: const [
              LlmRequestMessage(role: MessageRole.user, content: 'hello'),
            ],
          )
          .toList();

      // A gateway that folds a long JSON payload across two `data:` lines must
      // still yield one chunk; per-line jsonDecode drops both fragments.
      expect(chunks.map((c) => c.contentDelta).whereType<String>(), ['hello']);
      expect(chunks.single.finishReason, 'stop');
    },
  );

  test(
    'flushes a wrapped event when the stream ends without a blank line',
    () async {
      final adapter = _RecordingAdapter(
        sse: '''
data: {"choices":[{"delta":{"content":"tail end"}
data: ,"finish_reason":"stop"}]}''',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = OpenAiCompatibleProvider(dio: dio);

      final chunks = await provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.deepseek.com',
              apiKey: 'deepseek-test',
              model: 'deepseek-v4-pro',
            ),
            messages: const [
              LlmRequestMessage(role: MessageRole.user, content: 'hello'),
            ],
          )
          .toList();

      expect(chunks.map((c) => c.contentDelta).whereType<String>(), [
        'tail end',
      ]);
    },
  );

  test('[DONE] with trailing content ends the stream early', () async {
    final adapter = _RecordingAdapter(
      sse: '''
data: {"choices":[{"delta":{"content":"answer"},"finish_reason":null}]}
data: [DONE] extra
data: {"choices":[{"delta":{"content":"late"},"finish_reason":"stop"}]}
''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    final chunks = await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'deepseek-test',
            model: 'deepseek-v4-pro',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hello'),
          ],
        )
        .toList();

    // `[DONE] extra` must be recognized as the terminal event; otherwise the
    // client keeps waiting for the server to close the connection.
    expect(chunks.map((c) => c.contentDelta).whereType<String>(), ['answer']);
  });

  test(
    'reasoning_content is not sent back to non-reasoning providers',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final provider = OpenAiCompatibleProvider(dio: dio);

      await provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'openai-test',
              model: 'gpt-4o',
            ),
            messages: const [
              LlmRequestMessage(
                role: MessageRole.assistant,
                content: 'answer',
                reasoningContent: 'chain of thought',
              ),
            ],
          )
          .toList();

      final sent =
          (adapter.body['messages'] as List).single as Map<String, dynamic>;
      // A strict provider that rejects unknown fields would 400 on this.
      expect(sent, isNot(contains('reasoning_content')));
    },
  );

  test(
    'reasoning_content still round-trips for DeepSeek and reasoners',
    () async {
      for (final model in [
        'deepseek-v4-flash',
        'deepseek-v4-pro',
        'grok-4.5',
        'o1-preview',
      ]) {
        final adapter = _RecordingAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final provider = OpenAiCompatibleProvider(dio: dio);

        await provider
            .streamChat(
              config: LlmConfig(
                baseUrl: 'https://api.example.com/v1',
                apiKey: 'k',
                model: model,
              ),
              messages: const [
                LlmRequestMessage(
                  role: MessageRole.assistant,
                  content: 'a',
                  reasoningContent: 'r',
                ),
              ],
            )
            .toList();

        final sent =
            (adapter.body['messages'] as List).single as Map<String, dynamic>;
        expect(sent['reasoning_content'], 'r', reason: model);
      }
    },
  );

  test('forceToolName required sets tool_choice required', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'openai-test',
            model: 'gpt-4o',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hi'),
          ],
          tools: const [
            ToolSpec(
              name: 'web_search',
              description: 'search',
              parameters: {'type': 'object', 'properties': <String, dynamic>{}},
            ),
          ],
          forceToolName: kToolChoiceRequired,
        )
        .toList();

    expect(adapter.body['tool_choice'], 'required');
  });

  test('forceToolName sets function tool_choice', () async {
    final adapter = _RecordingAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = OpenAiCompatibleProvider(dio: dio);

    await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'openai-test',
            model: 'gpt-4o',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hi'),
          ],
          tools: const [
            ToolSpec(
              name: 'web_search',
              description: 'search',
              parameters: {'type': 'object', 'properties': <String, dynamic>{}},
            ),
          ],
          forceToolName: 'web_search',
        )
        .toList();

    expect(adapter.body['tool_choice'], {
      'type': 'function',
      'function': {'name': 'web_search'},
    });
  });

  test('stop wins over a hanging header wait', () async {
    final dio = Dio()..httpClientAdapter = _HangingAdapter();
    final provider = OpenAiCompatibleProvider(
      dio: dio,
      responseHeaderTimeout: const Duration(seconds: 30),
    );
    final token = CancelToken();

    final done = provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.example.com/v1',
            apiKey: 'test-key',
            model: 'test-model',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hello'),
          ],
          cancelToken: token,
        )
        .toList();

    // Let the request dispatch, then stop before any response header arrives.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel();

    await expectLater(done, completes);
  });
}

class _HangingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => Completer<ResponseBody>().future;

  @override
  void close({bool force = false}) {}
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({
    this.sse = '''
data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}
data: [DONE]
''',
  });

  final String sse;
  Map<String, dynamic> body = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    body = jsonDecode(options.data as String) as Map<String, dynamic>;
    return ResponseBody.fromString(
      sse,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
