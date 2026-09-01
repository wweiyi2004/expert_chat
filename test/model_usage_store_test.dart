import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/model_usage_store.dart';
import 'package:expert_chat/domain/llm/usage_tracking_llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('usage accumulates by endpoint and model and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ModelUsageStore(prefs);

    store.record(
      endpoint: 'https://api.example.com/v1/',
      model: 'chat-model',
      usage: const LlmUsage(
        inputTokens: 100,
        outputTokens: 20,
        cachedInputTokens: 60,
        reasoningTokens: 5,
      ),
    );
    store.record(
      endpoint: 'https://api.example.com/v1',
      model: 'chat-model',
      usage: const LlmUsage(
        inputTokens: 50,
        outputTokens: 10,
        cachedInputTokens: 20,
      ),
    );
    await store.flush();

    final restored = ModelUsageStore(prefs);
    final usage = restored.find(
      endpoint: 'HTTPS://API.EXAMPLE.COM/v1',
      model: 'chat-model',
    );
    expect(usage, isNotNull);
    expect(usage!.requests, 2);
    expect(usage.inputTokens, 150);
    expect(usage.outputTokens, 30);
    expect(usage.cachedInputTokens, 80);
    expect(usage.reasoningTokens, 5);
  });

  test('clear can remove one provider without touching another', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = ModelUsageStore(prefs);
    const usage = LlmUsage(inputTokens: 10, outputTokens: 2);

    store.record(endpoint: 'https://one.example/v1', model: 'm', usage: usage);
    store.record(endpoint: 'https://two.example/v1', model: 'm', usage: usage);
    await store.clear(endpoint: 'https://one.example/v1');

    expect(store.forEndpoint('https://one.example/v1'), isEmpty);
    expect(store.forEndpoint('https://two.example/v1'), hasLength(1));
  });

  test(
    'tracking provider records usage without changing streamed chunks',
    () async {
      final recorded = <LlmUsage>[];
      final provider = UsageTrackingLlmProvider(
        delegate: _FakeProvider(),
        onUsage: (_, usage) => recorded.add(usage),
      );

      final chunks = await provider
          .streamChat(
            config: const LlmConfig(
              baseUrl: 'https://api.example/v1',
              apiKey: 'k',
              model: 'm',
            ),
            messages: const [
              LlmRequestMessage(role: MessageRole.user, content: 'hi'),
            ],
          )
          .toList();

      expect(chunks.map((chunk) => chunk.contentDelta).whereType<String>(), [
        'ok',
      ]);
      expect(recorded.single.inputTokens, 9);
      expect(recorded.single.outputTokens, 3);
    },
  );
}

class _FakeProvider implements LlmProvider {
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    dynamic cancelToken,
  }) async* {
    yield const ChatChunk(contentDelta: 'ok');
    yield const ChatChunk(usage: LlmUsage(inputTokens: 9, outputTokens: 3));
  }
}
