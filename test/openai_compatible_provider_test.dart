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
