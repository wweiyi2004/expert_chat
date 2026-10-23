import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/llm/responses_api_provider.dart';
import 'package:expert_chat/domain/llm/anthropic_messages_provider.dart';
import 'package:expert_chat/domain/llm/gemini_native_provider.dart';
import 'package:expert_chat/domain/llm/prioritized_llm_provider.dart';

const config = LlmConfig(
  baseUrl: 'https://example.invalid/v1',
  apiKey: 'test',
  model: 'model',
);

class _SlowHeaders implements HttpClientAdapter {
  _SlowHeaders(this.body);
  final String body;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RecordingProvider implements LlmProvider {
  final configs = <LlmConfig>[];
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    configs.add(config);
    yield const ChatChunk(contentDelta: 'done', finishReason: 'stop');
  }
}

void main() {
  test(
    'old settings migrate to 120 seconds; custom timeout survives persistence and clamps',
    () {
      expect(
        TaskBudgetPrefs.fromJson({
          'workSeconds': 300,
        }).workResponseTimeoutSeconds,
        120,
      );
      final prefs = TaskBudgetPrefs.forPreset(
        TaskBudgetPreset.deep,
      ).copyWith(workResponseTimeoutSeconds: 240);
      expect(
        TaskBudgetPrefs.fromJson(prefs.toJson()).workResponseTimeoutSeconds,
        240,
      );
      expect(
        TaskBudgetPrefs.fromJson({
          'workResponseTimeoutSeconds': 1,
        }).workResponseTimeoutSeconds,
        30,
      );
      expect(
        TaskBudgetPrefs.fromJson({
          'workResponseTimeoutSeconds': 9999,
        }).workResponseTimeoutSeconds,
        600,
      );
      expect(
        config
            .copyWith(responseHeaderTimeout: const Duration(seconds: 120))
            .copyWith(model: 'other')
            .responseHeaderTimeout,
        const Duration(seconds: 120),
      );
    },
  );

  final cases = <String, (String, LlmProvider Function(Dio))>{
    'chat': (
      'data: [DONE]\n\n',
      (dio) => OpenAiCompatibleProvider(
        dio: dio,
        responseHeaderTimeout: const Duration(milliseconds: 5),
      ),
    ),
    'responses': (
      'event: response.completed\ndata: {"type":"response.completed","response":{}}\n\n',
      (dio) => ResponsesApiProvider(
        dio: dio,
        responseHeaderTimeout: const Duration(milliseconds: 5),
      ),
    ),
    'anthropic': (
      'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n',
      (dio) => AnthropicMessagesProvider(
        dio: dio,
        responseHeaderTimeout: const Duration(milliseconds: 5),
      ),
    ),
    'gemini': (
      'data: {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"done"}]}}]}\n\n',
      (dio) => GeminiNativeProvider(
        dio: dio,
        responseHeaderTimeout: const Duration(milliseconds: 5),
      ),
    ),
  };
  for (final entry in cases.entries) {
    test(
      '${entry.key}: per-request work timeout tolerates delayed headers while default still times out',
      () async {
        final dio = Dio()..httpClientAdapter = _SlowHeaders(entry.value.$1);
        addTearDown(() => dio.close(force: true));
        final provider = entry.value.$2(dio);
        await provider
            .streamChat(
              config: config.copyWith(
                responseHeaderTimeout: const Duration(seconds: 2),
              ),
              messages: [],
            )
            .toList();
        await expectLater(
          provider.streamChat(config: config, messages: []).toList(),
          throwsA(
            isA<LlmHttpException>().having(
              (e) => e.diagnostic,
              'phase',
              contains('等待响应头'),
            ),
          ),
        );
      },
    );
  }

  test(
    'pinning a provider does not pin an outdated per-request timeout',
    () async {
      final recorder = _RecordingProvider();
      final provider = PrioritizedLlmProvider(
        delegate: recorder,
        candidates: (c) async => [c],
        credentials: (c) async => c,
      );
      final first = config.copyWith(
        routingSessionId: 'task',
        responseHeaderTimeout: const Duration(seconds: 120),
      );
      await provider.streamChat(config: first, messages: []).toList();
      await provider
          .streamChat(
            config: first.copyWith(
              responseHeaderTimeout: const Duration(seconds: 240),
            ),
            messages: [],
          )
          .toList();
      expect(
        recorder.configs.last.responseHeaderTimeout,
        const Duration(seconds: 240),
      );
    },
  );
}
