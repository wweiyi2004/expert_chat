import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/responses_api_provider.dart';
import 'package:expert_chat/domain/llm/routing_llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('deepseek-v4-flash advertises server web search; pro does not', () {
    expect(
      ModelCapabilities.resolve('deepseek-v4-flash').supportsServerWebSearch,
      isTrue,
    );
    expect(
      ModelCapabilities.resolve('deepseek-v4-pro').supportsServerWebSearch,
      isFalse,
    );
  });

  test('Responses request uses /responses + hosted web_search', () async {
    final adapter = _RecordingAdapter(
      sse: '''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"hello"}

event: response.completed
data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[]}}

''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = ResponsesApiProvider(dio: dio);

    final chunks = await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
            serverWebSearch: true,
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'hi'),
          ],
        )
        .toList();

    expect(adapter.path, endsWith('/responses'));
    expect(adapter.body['stream'], isTrue);
    final tools = adapter.body['tools'] as List<dynamic>;
    expect(
      tools.any((t) => t is Map && t['type'] == 'web_search'),
      isTrue,
    );
    expect(adapter.body['tool_choice'], 'auto');
    expect(chunks.map((c) => c.contentDelta).whereType<String>(), ['hello']);
    expect(chunks.last.finishReason, 'stop');
  });

  test('forceServerWebSearch sets tool_choice to web_search', () async {
    final adapter = _RecordingAdapter(
      sse: '''
event: response.completed
data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[]}}

''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = ResponsesApiProvider(dio: dio);

    await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
            serverWebSearch: true,
            forceServerWebSearch: true,
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'news'),
          ],
        )
        .toList();

    expect(adapter.body['tool_choice'], {'type': 'web_search'});
  });

  test('parses reasoning, web_search activity and citations', () async {
    final adapter = _RecordingAdapter(
      sse: '''
event: response.web_search_call.searching
data: {"type":"response.web_search_call.searching","item_id":"ws_1","action":{"query":"Flutter 3.32"}}

event: response.web_search_call.completed
data: {"type":"response.web_search_call.completed","item_id":"ws_1","action":{"query":"Flutter 3.32","sources":[{"title":"Flutter","url":"https://flutter.dev","snippet":"UI toolkit"}]}}

event: response.reasoning_text.delta
data: {"type":"response.reasoning_text.delta","delta":"think"}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"answer"}

event: response.completed
data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[{"type":"web_search_call","id":"ws_1","action":{"query":"Flutter 3.32","sources":[{"title":"Flutter","url":"https://flutter.dev","snippet":"UI toolkit"}]}},{"type":"message","id":"m1","role":"assistant","content":[{"type":"output_text","text":"answer","annotations":[{"type":"url_citation","url":"https://flutter.dev","title":"Flutter"}]}]}]}}

''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = ResponsesApiProvider(dio: dio);

    final chunks = await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
            serverWebSearch: true,
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'Flutter?'),
          ],
        )
        .toList();

    final activities = chunks
        .map((c) => c.serverSearchActivity)
        .whereType<SearchActivity>()
        .toList();
    expect(activities, isNotEmpty);
    expect(activities.first.query, 'Flutter 3.32');
    expect(activities.first.status, SearchActivityStatus.running);
    expect(activities.last.status, SearchActivityStatus.done);

    expect(chunks.map((c) => c.reasoningDelta).whereType<String>(), ['think']);
    expect(chunks.map((c) => c.contentDelta).whereType<String>(), ['answer']);

    final cites = chunks
        .expand((c) => c.citations ?? const <Citation>[])
        .toList();
    expect(cites, isNotEmpty);
    expect(cites.first.url, 'https://flutter.dev');
  });

  test('function_call finish yields tool_calls + response items', () async {
    final adapter = _RecordingAdapter(
      sse: '''
event: response.output_item.done
data: {"type":"response.output_item.done","item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"fetch_url","arguments":"{\\"url\\":\\"https://example.com\\"}"}}

event: response.function_call_arguments.done
data: {"type":"response.function_call_arguments.done","item_id":"fc_1","call_id":"call_1","name":"fetch_url","arguments":"{\\"url\\":\\"https://example.com\\"}"}

event: response.completed
data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[{"type":"function_call","id":"fc_1","call_id":"call_1","name":"fetch_url","arguments":"{\\"url\\":\\"https://example.com\\"}"}]}}

''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = ResponsesApiProvider(dio: dio);

    final chunks = await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
            serverWebSearch: true,
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'read'),
          ],
          tools: const [
            ToolSpec(
              name: 'fetch_url',
              description: 'fetch',
              parameters: {'type': 'object'},
            ),
          ],
        )
        .toList();

    final last = chunks.last;
    expect(last.finishReason, 'tool_calls');
    expect(last.toolCalls, isNotNull);
    expect(last.toolCalls!.single.name, 'fetch_url');
    expect(last.responseOutputItems, isNotNull);
    expect(last.responseOutputItems!.single['type'], 'function_call');
  });

  test('RoutingLlmProvider uses Responses only when server search is on',
      () async {
    final chatAdapter = _RecordingAdapter(
      pathHint: 'chat',
      sse: '''
data: {"choices":[{"delta":{"content":"chat"},"finish_reason":"stop"}]}
data: [DONE]
''',
    );
    final responsesAdapter = _RecordingAdapter(
      pathHint: 'responses',
      sse: '''
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"resp"}

event: response.completed
data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[]}}

''',
    );
    final chatDio = Dio()..httpClientAdapter = chatAdapter;
    final respDio = Dio()..httpClientAdapter = responsesAdapter;
    final router = RoutingLlmProvider(
      chatCompletions: OpenAiCompatibleProvider(dio: chatDio),
      responses: ResponsesApiProvider(dio: respDio),
    );

    final chatChunks = await router
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'a'),
          ],
        )
        .toList();
    expect(chatChunks.map((c) => c.contentDelta).whereType<String>(), ['chat']);
    expect(chatAdapter.path, contains('chat/completions'));

    final respChunks = await router
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
            serverWebSearch: true,
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'b'),
          ],
        )
        .toList();
    expect(respChunks.map((c) => c.contentDelta).whereType<String>(), ['resp']);
    expect(responsesAdapter.path, endsWith('/responses'));
  });

  test('thinking maps to reasoning.effort', () async {
    final adapter = _RecordingAdapter(
      sse: '''
event: response.completed
data: {"type":"response.completed","response":{"id":"r1","status":"completed","output":[]}}

''',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final provider = ResponsesApiProvider(dio: dio);

    await provider
        .streamChat(
          config: const LlmConfig(
            baseUrl: 'https://api.deepseek.com',
            apiKey: 'k',
            model: 'deepseek-v4-flash',
            serverWebSearch: true,
          ),
          messages: const [
            LlmRequestMessage(role: MessageRole.user, content: 'x'),
          ],
          thinking: true,
        )
        .toList();

    expect(adapter.body['reasoning'], {'effort': 'high'});
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({
    required this.sse,
    this.pathHint,
  });

  final String sse;
  final String? pathHint;
  Map<String, dynamic> body = const {};
  String path = '';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    path = options.uri.path;
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
