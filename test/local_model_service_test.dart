import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_discovery.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';

void main() {
  test(
    'explicit no-auth local service scans and streams without retained key header',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        expect(request.headers.value('authorization'), isNull);
        await request.drain<void>();
        if (request.uri.path.endsWith('/models')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"data":[{"id":"local-fixture"}]}');
        } else {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write(
            'data: {"choices":[{"delta":{"content":"local ok"},"finish_reason":null}]}\n\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
        }
        await request.response.close();
      });
      final config = LlmConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'retained-key-not-sent',
        model: 'local-fixture',
        authMode: 'none',
        apiFormat: LlmApiFormat.openAiCompatible,
      );
      expect(config.isReady, true);
      expect(await ModelDiscovery().scan(config, CancelToken()), [
        'local-fixture',
      ]);
      final chunks = await OpenAiCompatibleProvider()
          .streamChat(config: config, messages: [])
          .toList();
      expect(
        chunks.map((chunk) => chunk.contentDelta ?? '').join(),
        'local ok',
      );
      expect(paths, ['/v1/models', '/v1/chat/completions']);
    },
  );
}
