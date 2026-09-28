import 'dart:async';
import 'package:dio/dio.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_connection_tester.dart';
import 'package:flutter_test/flutter_test.dart';

class _Llm implements LlmProvider {
  _Llm(this.stream);
  final Stream<ChatChunk> stream;
  LlmConfig? config;
  List<LlmRequestMessage>? messages;
  int calls = 0;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    calls++;
    this.config = config;
    this.messages = messages;
    expect(thinking, isFalse);
    expect(tools, isNull);
    return stream;
  }
}

const config = LlmConfig(
  baseUrl: 'https://example.com/v1',
  apiKey: 'test-key',
  model: 'model',
  serverWebSearch: true,
  forceServerWebSearch: true,
);

void main() {
  test(
    'probe verifies a visible reply and sends only its own short message',
    () async {
      final llm = _Llm(
        Stream.fromIterable(const [
          ChatChunk(reasoningDelta: 'planning'),
          ChatChunk(contentDelta: 'OK'),
        ]),
      );
      final token = CancelToken();
      await ModelConnectionTester(llm).check(config, cancelToken: token);
      expect(llm.calls, 1);
      expect(llm.messages, hasLength(1));
      expect(llm.messages!.single.content, '连接测试。请仅回复 OK。');
      expect(llm.config!.serverWebSearch, isFalse);
      expect(llm.config!.allowReasoningRetry, isFalse);
      expect(token.isCancelled, isTrue);
    },
  );

  test(
    'reasoning-only completion is not a successful connection check',
    () async {
      final llm = _Llm(
        Stream.value(const ChatChunk(reasoningDelta: 'only thinking')),
      );
      await expectLater(
        ModelConnectionTester(llm).check(config, cancelToken: CancelToken()),
        throwsFormatException,
      );
      expect(llm.calls, 1);
    },
  );

  test(
    'absolute deadline cancels a stream that has not returned an answer',
    () async {
      final stream = StreamController<ChatChunk>();
      final llm = _Llm(stream.stream);
      final token = CancelToken();
      final running = ModelConnectionTester(
        llm,
        timeout: const Duration(milliseconds: 20),
      ).check(config, cancelToken: token);
      stream.add(const ChatChunk(reasoningDelta: 'thinking'));
      await expectLater(running, throwsA(isA<TimeoutException>()));
      expect(token.isCancelled, isTrue);
      await stream.close();
    },
  );

  test(
    'cancelled checks neither report success nor submit a second request',
    () async {
      final stream = StreamController<ChatChunk>();
      final llm = _Llm(stream.stream);
      final token = CancelToken();
      final pending = ModelConnectionTester(
        llm,
      ).check(config, cancelToken: token);
      token.cancel('user cancelled');
      await expectLater(
        pending,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      final preCancelled = CancelToken()..cancel();
      await expectLater(
        ModelConnectionTester(llm).check(config, cancelToken: preCancelled),
        throwsA(isA<DioException>()),
      );
      expect(llm.calls, 1);
      await stream.close();
    },
  );
}
