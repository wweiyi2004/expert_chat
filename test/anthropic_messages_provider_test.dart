import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/anthropic_messages_provider.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';

const _config = LlmConfig(
  baseUrl: 'https://api.anthropic.com',
  apiKey: 'synthetic',
  model: 'claude-sonnet-4-6',
  apiFormat: LlmApiFormat.anthropicMessages,
);
const _tool = ToolSpec(
  name: 'lookup',
  description: 'look up',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string'},
    },
  },
);
const _user = LlmRequestMessage(role: MessageRole.user, content: 'hello');

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);
  final Stream<Uint8List> Function() body;
  RequestOptions? request;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody(
      body(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _sse(List<Map<String, dynamic>> events) => events
    .map((e) => 'event: ${e['type']}\r\ndata: ${jsonEncode(e)}\r\n\r\n')
    .join();
List<Map<String, dynamic>> _events({String finish = 'tool_use'}) => [
  {
    'type': 'message_start',
    'message': {
      'usage': {
        'input_tokens': 5,
        'output_tokens': 1,
        'cache_read_input_tokens': 10,
        'cache_creation_input_tokens': 3,
      },
    },
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'thinking_delta', 'thinking': '思考'},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'signature_delta', 'signature': 'signed-'},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'signature_delta', 'signature': 'value'},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {'type': 'redacted_thinking', 'data': 'opaque'},
  },
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'content_block_start',
    'index': 2,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 2,
    'delta': {'type': 'text_delta', 'text': '正在查询'},
  },
  {'type': 'content_block_stop', 'index': 2},
  {
    'type': 'content_block_start',
    'index': 3,
    'content_block': {
      'type': 'tool_use',
      'id': 'tool-1',
      'name': 'lookup',
      'input': {},
    },
  },
  {
    'type': 'content_block_delta',
    'index': 3,
    'delta': {'type': 'input_json_delta', 'partial_json': '{"query":'},
  },
  {
    'type': 'content_block_delta',
    'index': 3,
    'delta': {'type': 'input_json_delta', 'partial_json': '"测试"}'},
  },
  {'type': 'content_block_stop', 'index': 3},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': finish},
    'usage': {'output_tokens': 8},
  },
  {'type': 'message_stop'},
];

({AnthropicMessagesProvider provider, _Adapter adapter}) _provider(String sse) {
  final bytes = utf8.encode(sse);
  final adapter = _Adapter(() async* {
    // Deliberately split inside UTF-8 sequences and SSE/JSON boundaries.
    for (var i = 0; i < bytes.length; i += 7) {
      yield Uint8List.fromList(
        bytes.sublist(i, i + 7 < bytes.length ? i + 7 : bytes.length),
      );
    }
  });
  final dio = Dio()..httpClientAdapter = adapter;
  addTearDown(() => dio.close(force: true));
  return (provider: AnthropicMessagesProvider(dio: dio), adapter: adapter);
}

void main() {
  test(
    'stream preserves thinking signatures, tool JSON and cumulative usage',
    () async {
      final h = _provider(_sse(_events()));
      final chunks = await h.provider
          .streamChat(
            config: _config,
            messages: [_user],
            tools: [_tool],
            thinking: true,
          )
          .toList();
      expect(
        chunks.map((c) => c.contentDelta).whereType<String>().join(),
        '正在查询',
      );
      expect(
        chunks.map((c) => c.reasoningDelta).whereType<String>().join(),
        '思考',
      );
      expect(chunks.where((c) => c.toolCalls != null), hasLength(1));
      final last = chunks.last;
      expect(last.finishReason, 'tool_calls');
      expect(last.toolCalls!.single.id, 'tool-1');
      expect(jsonDecode(last.toolCalls!.single.argumentsJson), {'query': '测试'});
      expect(last.responseOutputItems![0], {
        'type': 'thinking',
        'thinking': '思考',
        'signature': 'signed-value',
      });
      expect(last.responseOutputItems![1], {
        'type': 'redacted_thinking',
        'data': 'opaque',
      });
      expect(last.usage!.inputTokens, 18);
      expect(last.usage!.cachedInputTokens, 10);
      expect(last.usage!.outputTokens, 8);
      expect(
        h.adapter.request!.uri.toString(),
        'https://api.anthropic.com/v1/messages',
      );
      expect(h.adapter.request!.headers.containsKey('Authorization'), false);
      final body = jsonDecode(h.adapter.request!.data as String);
      expect(body['thinking'], {'type': 'adaptive'});

      final continued = AnthropicMessagesProvider.buildRequestBody(
        config: _config,
        messages: [
          _user,
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: '正在查询',
            toolCalls: last.toolCalls!,
            responseOutputItems: last.responseOutputItems!,
          ),
          const LlmRequestMessage(
            role: MessageRole.tool,
            content: 'result',
            toolCallId: 'tool-1',
          ),
          const LlmRequestMessage(
            role: MessageRole.user,
            content: 'screen',
            isToolImageObservation: true,
            toolImageCallId: 'tool-1',
            imageDataUrls: ['data:image/png;base64,YQ=='],
          ),
        ],
      );
      expect(continued['messages'][1]['content'], last.responseOutputItems);
      final result = continued['messages'][2]['content'][0];
      expect(result['type'], 'tool_result');
      expect(result['tool_use_id'], 'tool-1');
      expect(result['content'].last['source'], {
        'type': 'base64',
        'media_type': 'image/png',
        'data': 'YQ==',
      });
    },
  );

  test(
    'truncated stream never exposes even a syntactically complete tool call',
    () async {
      final h = _provider(_sse(_events()..removeLast()));
      final seen = <ChatChunk>[];
      await expectLater(
        h.provider
            .streamChat(config: _config, messages: [_user])
            .forEach(seen.add),
        throwsStateError,
      );
      expect(seen.every((c) => c.toolCalls == null), true);
    },
  );

  test('max_tokens does not execute tool blocks', () async {
    final h = _provider(_sse(_events(finish: 'max_tokens')));
    final chunks = await h.provider
        .streamChat(config: _config, messages: [_user])
        .toList();
    expect(chunks.last.finishReason, 'length');
    expect(chunks.every((c) => c.toolCalls == null), true);
  });

  test('stream error is surfaced after partial text', () async {
    final events = _events().take(10).toList()
      ..add({
        'type': 'error',
        'error': {'type': 'overloaded_error', 'message': 'busy'},
      });
    final h = _provider(_sse(events));
    await expectLater(
      h.provider.streamChat(config: _config, messages: [_user]).toList(),
      throwsA(predicate((e) => e.toString().contains('busy'))),
    );
  });

  test('tools are not emitted when a block never closes', () async {
    final events = _events()
      ..removeWhere(
        (e) => e['type'] == 'content_block_stop' && e['index'] == 3,
      );
    final h = _provider(_sse(events));
    await expectLater(
      h.provider.streamChat(config: _config, messages: [_user]).toList(),
      throwsStateError,
    );
  });

  test('system prompts and consecutive tool results have native roles', () {
    final body = AnthropicMessagesProvider.buildRequestBody(
      config: _config,
      messages: [
        const LlmRequestMessage(role: MessageRole.system, content: 'system'),
        _user,
        const LlmRequestMessage(
          role: MessageRole.assistant,
          content: '',
          toolCalls: [
            ToolCall(index: 0, id: 'a', name: 'lookup', argumentsJson: '{}'),
            ToolCall(index: 1, id: 'b', name: 'lookup', argumentsJson: '{}'),
          ],
        ),
        const LlmRequestMessage(
          role: MessageRole.tool,
          content: 'a-result',
          toolCallId: 'a',
        ),
        const LlmRequestMessage(
          role: MessageRole.tool,
          content: 'b-result',
          toolCallId: 'b',
        ),
      ],
      tools: [_tool],
    );
    expect(body['system'], [
      {'type': 'text', 'text': 'system'},
    ]);
    expect(body['messages'], hasLength(3));
    expect(body['messages'].last['role'], 'user');
    expect(body['messages'].last['content'], hasLength(2));
    expect(body['tools'][0]['input_schema'], _tool.parameters);
  });

  test(
    'manual thinking leaves output budget and forced tools disable thinking',
    () {
      final config = _config.copyWith(model: 'claude-sonnet-4-5');
      final body = AnthropicMessagesProvider.buildRequestBody(
        config: config,
        messages: [_user],
        thinking: true,
        reasoningEffort: ReasoningEffort.max,
      );
      expect(body['thinking']['type'], 'enabled');
      expect(
        body['max_tokens'],
        greaterThan(body['thinking']['budget_tokens'] as int),
      );
      final forced = AnthropicMessagesProvider.buildRequestBody(
        config: config,
        messages: [_user],
        tools: [_tool],
        forceToolName: 'lookup',
        thinking: true,
      );
      expect(forced['thinking'], {'type': 'disabled'});
      expect(forced['tool_choice'], {'type': 'tool', 'name': 'lookup'});
    },
  );

  test('pre-cancelled request never contacts the endpoint', () async {
    final h = _provider(_sse(_events()));
    await h.provider
        .streamChat(
          config: _config,
          messages: [_user],
          cancelToken: CancelToken()..cancel('stop'),
        )
        .toList();
    expect(h.adapter.request, isNull);
  });

  test(
    'foreign file IDs and foreign raw response items fail before sending',
    () {
      expect(
        () => AnthropicMessagesProvider.buildRequestBody(
          config: _config,
          messages: [
            const LlmRequestMessage(
              role: MessageRole.user,
              content: '',
              imageFileIds: ['other-provider-id'],
            ),
          ],
        ),
        throwsStateError,
      );
      expect(
        () => AnthropicMessagesProvider.buildRequestBody(
          config: _config,
          messages: [
            const LlmRequestMessage(
              role: MessageRole.assistant,
              content: '',
              responseOutputItems: [
                {
                  'functionCall': {'name': 'test'},
                },
              ],
            ),
          ],
        ),
        throwsStateError,
      );
    },
  );
}
