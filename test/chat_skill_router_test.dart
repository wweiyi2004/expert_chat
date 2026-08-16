import 'package:dio/dio.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/chat_skill_router.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _DripLlm implements LlmProvider {
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    for (var i = 0; i < 20; i++) {
      if (cancelToken?.isCancelled == true) return;
      yield const ChatChunk(contentDelta: 'x');
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }
}

class _FakeLlm implements LlmProvider {
  _FakeLlm(this.output, {this.onCall});
  final String output;
  int calls = 0;
  void Function(List<LlmRequestMessage> messages)? onCall;

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls += 1;
    onCall?.call(messages);
    expect(thinking, isFalse);
    yield ChatChunk(contentDelta: output);
  }
}

void main() {
  final catalog = ChatSkillCatalog.factory();
  const router = ChatSkillRouter();
  const config = LlmConfig(
    baseUrl: 'https://example.com',
    apiKey: 'k',
    model: 'chat',
  );

  test('prefix skips the classifier', () async {
    final llm = _FakeLlm('{"skill":"writing","confidence":0.99}');
    final route = await router.route(
      userText: '/代码 重构这段',
      recent: const [],
      catalog: catalog,
      llm: llm,
      config: config,
    );
    expect(route.skill.id, 'code');
    expect(route.source, ChatSkillSource.prefix);
    expect(llm.calls, 0);
  });

  test('valid classifier json selects that skill', () async {
    final llm = _FakeLlm('{"skill":"writing","confidence":0.9}');
    final route = await router.route(
      userText: '把这段改得更顺',
      recent: const [],
      catalog: catalog,
      llm: llm,
      config: config,
    );
    expect(route.skill.id, 'writing');
    expect(route.source, ChatSkillSource.model);
    expect(llm.calls, 1);
  });

  test('classifier prompt lists a newly added skill id', () {
    final custom = ChatSkillCatalog([
      ...catalog.skills,
      const ChatSkill(
        id: 'legal',
        name: '法务',
        when: '合同、条款、合规',
        prompt: '只指出风险',
      ),
    ]);
    final system = router.classifierSystemPrompt(custom);
    expect(system, contains('legal'));
    expect(system, contains('合同、条款、合规'));
    expect(system, isNot(contains('只指出风险')));
  });

  test('unknown id, low confidence, and bad json fall back', () async {
    for (final raw in [
      '{"skill":"nope","confidence":0.99}',
      '{"skill":"writing","confidence":0.2}',
      'not-json',
    ]) {
      final route = await router.route(
        userText: '你好',
        recent: const [],
        catalog: catalog,
        llm: _FakeLlm(raw),
        config: config,
      );
      expect(route.skill.id, 'general', reason: raw);
      expect(route.source, ChatSkillSource.fallback);
    }
  });

  test('wall-clock timeout beats a slow drip and returns fallback', () async {
    final sw = Stopwatch()..start();
    final route = await router.route(
      userText: '把这段改得更顺',
      recent: const [],
      catalog: catalog,
      llm: _DripLlm(),
      config: config,
      timeout: const Duration(milliseconds: 50),
    );
    sw.stop();
    expect(route.skill.id, 'general');
    expect(route.source, ChatSkillSource.fallback);
    expect(sw.elapsedMilliseconds, lessThan(200));
  });

  test('classifier user prompt includes recent turns and strips nothing required', () {
    final text = router.classifierUserPrompt(
      userText: '再短一点',
      recent: [
        ChatMessage(role: MessageRole.user, content: '写一段开场'),
        ChatMessage(role: MessageRole.assistant, content: '很长的开场……'),
      ],
    );
    expect(text, contains('再短一点'));
    expect(text, contains('写一段开场'));
  });
}
