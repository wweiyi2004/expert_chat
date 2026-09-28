import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/data/jev_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/chat_skill_router.dart';
import 'package:expert_chat/domain/llm/jev_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  Map<String, dynamic>? body;
  RequestOptions? request;
  int calls = 0;
  int status = 200;
  String choice = 'code';
  double confidence = 0.9;
  Object? responseOverride;
  bool waitForCancel = false;
  bool cancelled = false;
  final started = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    request = options;
    body =
        jsonDecode(
              await requestStream!
                  .cast<List<int>>()
                  .transform(utf8.decoder)
                  .join(),
            )
            as Map<String, dynamic>;
    if (!started.isCompleted) started.complete();
    if (waitForCancel) {
      await cancelFuture;
      cancelled = true;
    }
    final criteria =
        ((body!['questions'] as Map)['skill'] as Map)['criteria'] as Map;
    return ResponseBody.fromString(
      jsonEncode(
        responseOverride ??
            {
              'answers': {
                'skill': {
                  'type': 'choice',
                  'choice': choice,
                  'confidence': confidence,
                  'probabilities': {
                    for (final key in criteria.keys)
                      key: key == choice ? 1.0 : 0.0,
                  },
                },
              },
            },
      ),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Llm implements LlmProvider {
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
  }) async* {
    calls++;
    yield const ChatChunk(contentDelta: '{"skill":"writing","confidence":0.9}');
  }
}

void main() {
  late _Adapter adapter;
  late JevClient client;
  late _Llm llm;
  const router = ChatSkillRouter();
  final catalog = ChatSkillCatalog.factory();
  const enabled = JevConfig(enabled: true);
  const llmConfig = LlmConfig(
    baseUrl: 'https://unused.invalid',
    apiKey: 'llm-key',
    model: 'chat',
  );

  setUp(() {
    adapter = _Adapter();
    client = JevClient(dio: Dio()..httpClientAdapter = adapter);
    llm = _Llm();
    addTearDown(client.close);
  });

  Future<ChatSkillRoute> route({
    String text = '帮我修复这段 Dart 代码',
    JevConfig config = enabled,
    String key = 'test-jev-key',
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 10),
    ChatSkillCatalog? skills,
    List<ChatMessage> recent = const [],
  }) => router.route(
    userText: text,
    recent: recent,
    catalog: skills ?? catalog,
    llm: llm,
    config: llmConfig,
    jevConfig: config,
    jevApiKey: key,
    jevClient: client,
    cancelToken: cancel,
    timeout: timeout,
  );

  test(
    'native Choice request selects skill without calling chat model',
    () async {
      final result = await route();
      expect(result.skill.id, 'code');
      expect(result.source, ChatSkillSource.jev);
      expect(llm.calls, 0);
      expect(
        adapter.request!.uri.toString(),
        'https://api.typesafe.ai/v1/systemone',
      );
      expect(adapter.request!.headers['Authorization'], 'Bearer test-jev-key');
      expect(adapter.request!.followRedirects, isFalse);
      expect(adapter.body!['model'], 'jev-latest');
      expect(adapter.body!.containsKey('messages'), isFalse);
      final question = (adapter.body!['questions'] as Map)['skill'] as Map;
      expect(question['type'], 'choice');
      expect(
        (question['criteria'] as Map).keys.toSet(),
        catalog.enabled.map((s) => s.id).toSet(),
      );
      expect(
        jsonEncode(question),
        isNot(contains(catalog.skillById('code')!.prompt)),
      );
      expect(
        TurnSkillMark.fromJson(
          TurnSkillMark(id: 'code', name: '代码', source: result.source).toJson(),
        ).source,
        ChatSkillSource.jev,
      );
    },
  );

  test('explicit prefix avoids both classification providers', () async {
    final result = await route(text: '/翻译 你好');
    expect(result.source, ChatSkillSource.prefix);
    expect(adapter.calls, 0);
    expect(llm.calls, 0);
  });

  test('disabled or missing key keeps existing classification', () async {
    expect(
      (await route(config: const JevConfig())).source,
      ChatSkillSource.model,
    );
    expect((await route(key: '  ')).source, ChatSkillSource.model);
    expect(adapter.calls, 0);
    expect(llm.calls, 2);
  });

  test(
    'low confidence uses fallback without a second paid classification',
    () async {
      adapter.confidence = 0.65;
      final result = await route(config: enabled.copyWith(minConfidence: 0.7));
      expect(result.skill.id, catalog.fallback.id);
      expect(result.fallbackReason, ChatSkillFallbackReason.lowConfidence);
      expect(llm.calls, 0);
    },
  );

  test('disabled skills are not offered and context is bounded', () async {
    final skills = catalog.update(
      (s) => s.id == 'writing' ? s.copyWith(enabled: false) : s,
    );
    await route(
      skills: skills,
      text: '中' * 9000,
      recent: [
        ChatMessage(role: MessageRole.system, content: 'system-secret'),
        for (var i = 0; i < 6; i++)
          ChatMessage(role: MessageRole.user, content: '$i${'文' * 500}'),
      ],
    );
    final state = adapter.body!['state'] as String;
    final data = jsonDecode(state.substring(state.indexOf('{'))) as Map;
    expect((data['current_task'] as String).length, 8000);
    expect(data['recent_conversation'], hasLength(4));
    for (final message in data['recent_conversation'] as List) {
      expect((message['content'] as String).length, 400);
    }
    expect(state, isNot(contains('system-secret')));
    final criteria =
        ((adapter.body!['questions'] as Map)['skill'] as Map)['criteria']
            as Map;
    expect(criteria.containsKey('writing'), isFalse);
  });

  for (final status in [401, 403, 429, 500]) {
    test('HTTP $status falls back without exposing server errors', () async {
      adapter.status = status;
      adapter.responseOverride = {'error': 'test-jev-key private text'};
      final result = await route();
      expect(result.fallbackReason, ChatSkillFallbackReason.providerError);
      expect(llm.calls, 0);
    });
  }

  for (final body in <Object>[
    {},
    {
      'answers': {
        'skill': {'type': 'score'},
      },
    },
    {
      'answers': {
        'skill': {'type': 'choice', 'choice': 'not-a-skill', 'confidence': 1},
      },
    },
    {
      'answers': {
        'skill': {'type': 'choice', 'choice': 'code', 'confidence': '0.9'},
      },
    },
    {
      'answers': {
        'skill': {'type': 'choice', 'choice': 'code', 'confidence': 2},
      },
    },
  ]) {
    test('malformed result ${jsonEncode(body)} uses fallback', () async {
      adapter.responseOverride = body;
      expect(
        (await route()).fallbackReason,
        ChatSkillFallbackReason.invalidOutput,
      );
      expect(llm.calls, 0);
    });
  }

  test('timeout cancels transport and returns a usable fallback', () async {
    adapter.waitForCancel = true;
    final result = await route(timeout: const Duration(milliseconds: 100));
    expect(result.fallbackReason, ChatSkillFallbackReason.timeout);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.cancelled, isTrue);
    expect(llm.calls, 0);
  });

  test('user cancellation cancels transport without retry', () async {
    adapter.waitForCancel = true;
    final cancel = CancelToken();
    final pending = route(cancel: cancel);
    await adapter.started.future;
    cancel.cancel();
    expect((await pending).fallbackReason, ChatSkillFallbackReason.cancelled);
    expect(llm.calls, 0);
  });

  test('already cancelled does not start network request', () async {
    final cancel = CancelToken()..cancel();
    expect(
      (await route(cancel: cancel)).fallbackReason,
      ChatSkillFallbackReason.cancelled,
    );
    expect(adapter.calls, 0);
  });

  test('more than 255 options fails locally', () async {
    await expectLater(
      client.choose(
        apiKey: 'k',
        model: 'jev-latest',
        state: 'x',
        instructions: 'choose',
        criteria: {for (var i = 0; i < 256; i++) '$i': '$i'},
      ),
      throwsA(
        isA<JevException>().having(
          (e) => e.failure,
          'failure',
          JevFailure.invalidRequest,
        ),
      ),
    );
    expect(adapter.calls, 0);
  });
}
