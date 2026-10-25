import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:expert_chat/domain/remote/remote_model.dart';

void main() {
  for (final format in [
    'openAiCompatible',
    'openAiResponses',
    'anthropicMessages',
    'geminiNative',
  ]) {
    test('headless $format preserves real tool continuation', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var round = 0;
      final requests = <Map>[];
      server.listen((request) async {
        requests.add(
          jsonDecode(await utf8.decoder.bind(request).join()) as Map,
        );
        round++;
        final tool = round == 1;
        final events = <Map<String, dynamic>>[];
        if (format == 'openAiCompatible') {
          events.add({
            'choices': [
              {
                'delta': tool
                    ? {
                        'tool_calls': [
                          {
                            'index': 0,
                            'id': 'c1',
                            'type': 'function',
                            'function': {
                              'name': 'shell',
                              'arguments': '{"command":"echo fixture"}',
                            },
                          },
                        ],
                      }
                    : {'content': 'Verified fixture'},
                'finish_reason': tool ? 'tool_calls' : 'stop',
              },
            ],
          });
        } else if (format == 'openAiResponses') {
          if (tool) {
            events.add({
              'type': 'response.output_item.done',
              'item': {
                'type': 'function_call',
                'id': 'fc1',
                'call_id': 'c1',
                'name': 'shell',
                'arguments': '{"command":"echo fixture"}',
              },
            });
          } else {
            events.add({
              'type': 'response.output_text.delta',
              'delta': 'Verified fixture',
            });
          }
          events.add({
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'output': tool
                  ? [
                      {
                        'type': 'function_call',
                        'id': 'fc1',
                        'call_id': 'c1',
                        'name': 'shell',
                        'arguments': '{"command":"echo fixture"}',
                      },
                    ]
                  : [],
            },
          });
        } else if (format == 'anthropicMessages') {
          events.addAll([
            {'type': 'message_start', 'message': {}},
            {
              'type': 'content_block_start',
              'index': 0,
              'content_block': tool
                  ? {
                      'type': 'tool_use',
                      'id': 'c1',
                      'name': 'shell',
                      'input': {},
                    }
                  : {'type': 'text', 'text': ''},
            },
            {
              'type': 'content_block_delta',
              'index': 0,
              'delta': tool
                  ? {
                      'type': 'input_json_delta',
                      'partial_json': '{"command":"echo fixture"}',
                    }
                  : {'type': 'text_delta', 'text': 'Verified fixture'},
            },
            {'type': 'content_block_stop', 'index': 0},
            {
              'type': 'message_delta',
              'delta': {'stop_reason': tool ? 'tool_use' : 'end_turn'},
            },
            {'type': 'message_stop'},
          ]);
        } else {
          events.add({
            'candidates': [
              {
                'content': {
                  'role': 'model',
                  'parts': [
                    tool
                        ? {
                            'functionCall': {
                              'name': 'shell',
                              'args': {'command': 'echo fixture'},
                            },
                            'thoughtSignature': 'fixture-signature',
                          }
                        : {'text': 'Verified fixture'},
                  ],
                },
                'finishReason': 'STOP',
              },
            ],
          });
        }
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        for (final event in events) {
          if (event['type'] != null) {
            request.response.write('event: ${event['type']}\n');
          }
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      try {
        final model = RemoteModel();
        final history = <dynamic>[
          {'role': 'user', 'content': 'Verify fixture'},
        ];
        final first = await model.step(
          url: 'http://127.0.0.1:${server.port}',
          model: 'fixture',
          key: 'test',
          format: format,
          history: history,
          cancel: CancelToken(),
        );
        final call = (first['tool_calls'] as List).single as Map;
        expect(call['function']['name'], 'shell');
        history.addAll([
          first,
          {
            'role': 'tool',
            'tool_call_id': call['id'],
            'content': '{"exitCode":0,"output":"fixture"}',
          },
        ]);
        final second = await model.step(
          url: 'http://127.0.0.1:${server.port}',
          model: 'fixture',
          key: 'test',
          format: format,
          history: history,
          cancel: CancelToken(),
        );
        expect(second['content'], 'Verified fixture');
        expect(requests.length, 2);
        final request = jsonEncode(requests.last);
        expect(request, contains('fixture'));
        if (format == 'geminiNative') {
          expect(request, contains('fixture-signature'));
        }
      } finally {
        await server.close(force: true);
      }
    });
  }
}
