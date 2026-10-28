import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/host/llm_wire.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const _openAi = LlmConfig(
  baseUrl: 'https://api.openai.com/v1',
  apiKey: 'sk-test',
  model: 'gpt-5.1',
  apiFormat: LlmApiFormat.openAiCompatible,
);

void main() {
  test('only the official OpenAI API key endpoint supports fast mode', () {
    expect(_openAi.supportsPriorityTier, isTrue);
    expect(
      _openAi.copyWith(baseUrl: 'https://api.deepseek.com').supportsPriorityTier,
      isFalse,
    );
    expect(_openAi.copyWith(authMode: 'chatgpt').supportsPriorityTier, isFalse);
    expect(
      _openAi.copyWith(apiFormat: LlmApiFormat.anthropicMessages).supportsPriorityTier,
      isFalse,
    );
  });

  test('fast session policy maps to priority only where supported', () {
    const on = SessionPolicy(fast: true);
    expect(applyFastMode(on, _openAi).serviceTier, 'priority');
    expect(applyFastMode(const SessionPolicy(), _openAi).serviceTier, isNull);
    expect(applyFastMode(null, _openAi).serviceTier, isNull);
    final deepseek = _openAi.copyWith(baseUrl: 'https://api.deepseek.com');
    expect(applyFastMode(on, deepseek).serviceTier, isNull);
    // A tier carried by a previous route never leaks onto a model without support.
    expect(
      applyFastMode(on, deepseek.copyWith(serviceTier: 'priority')).serviceTier,
      isNull,
    );
  });

  test('fast survives persistence and the host wire', () {
    final restored = SessionPolicy.fromJson(
      jsonDecode(jsonEncode(const SessionPolicy(fast: true).toJson())) as Map<String, dynamic>,
    );
    expect(restored.fast, isTrue);
    expect(SessionPolicy.fromJson(const {}).fast, isFalse);
    final wired = decodeLlmConfig(
      jsonDecode(jsonEncode(encodeLlmConfig(_openAi.copyWith(serviceTier: 'priority'))))
          as Map<String, dynamic>,
    );
    expect(wired.serviceTier, 'priority');
  });

  test('request body carries service_tier only when set and supported', () async {
    Future<Map<String, dynamic>> body(LlmConfig config) async {
      final adapter = _RecordingAdapter();
      await OpenAiCompatibleProvider(dio: Dio()..httpClientAdapter = adapter)
          .streamChat(
            config: config,
            messages: const [LlmRequestMessage(role: MessageRole.user, content: 'hi')],
          )
          .toList();
      return adapter.body;
    }

    expect((await body(_openAi.copyWith(serviceTier: 'priority')))['service_tier'], 'priority');
    expect((await body(_openAi)).containsKey('service_tier'), isFalse);
    final other = _openAi.copyWith(baseUrl: 'https://example.com/v1', serviceTier: 'priority');
    expect((await body(other)).containsKey('service_tier'), isFalse);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  Map<String, dynamic> body = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    body = jsonDecode(options.data as String) as Map<String, dynamic>;
    return ResponseBody.fromString(
      'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\ndata: [DONE]\n',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
