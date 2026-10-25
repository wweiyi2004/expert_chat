import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/drift_conversation_repository.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/gemini_native_provider.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/routing_llm_provider.dart';
import 'package:expert_chat/domain/llm/usage_tracking_llm_provider.dart';
import 'package:expert_chat/domain/tools/search_provider.dart';
import 'package:expert_chat/domain/tools/tool_engine.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'gemini',
        name: 'Gemini relay',
        baseUrl: 'https://relay.example/native',
        chatModel: 'gemini-3.1-pro',
        reasonerModel: 'gemini-3.1-pro',
        apiFormat: LlmApiFormat.geminiNative,
      ),
    ],
    activeProfileId: 'gemini',
    selectedModel: 'gemini-3.1-pro',
    apiKey: 'synthetic-key',
    searchBackend: SearchBackend.deepseek,
    searchApiKey: 'fixture-official-search-key',
    imageGenMode: ImageGenMode.off,
  );
}

class _Search implements SearchProvider {
  final queries = <String>[];
  @override
  Future<List<SearchResult>> search(
    String query, {
    int maxResults = 8,
    CancelToken? cancelToken,
  }) async {
    queries.add(query);
    return [
      SearchResult(
        title: query,
        url: 'https://example.com/${queries.length}',
        content: 'Synthetic documentation result for $query.',
      ),
    ];
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final List<Map<String, dynamic>> bodies = [];
  final List<RequestOptions> requests = [];
  final List<Map<String, dynamic>> Function(int index) reply;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(jsonDecode(options.data as String) as Map<String, dynamic>);
    return ResponseBody.fromString(
      reply(
        bodies.length - 1,
      ).map((event) => 'data: ${jsonEncode(event)}\n\n').join(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _candidate(
  List<Map<String, dynamic>> parts,
  String finish,
) => {
  'candidates': [
    {
      'index': 0,
      'content': {'role': 'model', 'parts': parts},
      'finishReason': finish,
    },
  ],
};

const _signedCalls = [
  {
    'functionCall': {
      'id': 'native-a',
      'name': 'web_search',
      'args': {'query': 'Gemini native schema'},
    },
    'thoughtSignature': 'signature-a',
  },
  {
    'functionCall': {
      'id': 'native-b',
      'name': 'web_search',
      'args': {'query': 'Gemini tool responses'},
    },
  },
];

Future<ProviderContainer> _container(
  _Adapter adapter,
  _Search search,
  List<LlmUsage> usage,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final database = AppDatabase(NativeDatabase.memory());
  final routing = RoutingLlmProvider(
    geminiNative: GeminiNativeProvider(dio: Dio()..httpClientAdapter = adapter),
  );
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      appDatabaseProvider.overrideWithValue(database),
      conversationRepositoryProvider.overrideWithValue(
        DriftConversationRepository(database),
      ),
      settingsControllerProvider.overrideWith(_Settings.new),
      llmProvider.overrideWithValue(
        UsageTrackingLlmProvider(
          delegate: routing,
          onUsage: (_, value) => usage.add(value),
        ),
      ),
      toolEngineFactoryProvider.overrideWithValue(
        ({required backend, required apiKey}) => ToolEngine(search),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  await container.read(settingsControllerProvider.future);
  await container.read(chatControllerProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native Gemini parallel tools preserve parts and IDs through the real chat loop',
    () async {
      final adapter = _Adapter(
        (index) => index == 0
            ? [_candidate(_signedCalls, 'STOP')]
            : [
                _candidate([
                  {
                    'text': '已检索两份资料，结论已确认。',
                    'thoughtSignature': 'final-signature',
                  },
                ], 'STOP'),
                {
                  'usageMetadata': {
                    'promptTokenCount': 12,
                    'toolUsePromptTokenCount': 3,
                    'candidatesTokenCount': 8,
                    'thoughtsTokenCount': 5,
                    'cachedContentTokenCount': 4,
                    'totalTokenCount': 28,
                  },
                },
              ],
      );
      final search = _Search();
      final usage = <LlmUsage>[];
      final container = await _container(adapter, search, usage);
      final controller = container.read(chatControllerProvider.notifier);
      await controller.sendMessage('请检索 Gemini 原生协议并给出结论');
      final state = container.read(chatControllerProvider).requireValue;
      expect(state.error, isNull);
      expect(state.current!.messages.last.content, contains('结论已确认'));
      expect(search.queries, ['Gemini native schema', 'Gemini tool responses']);
      expect(adapter.bodies, hasLength(2));
      expect(
        adapter.requests.every(
          (r) => r.uri.path.endsWith(':streamGenerateContent'),
        ),
        isTrue,
      );
      final contents = adapter.bodies.last['contents'] as List;
      final model = contents.singleWhere((c) => c['role'] == 'model') as Map;
      expect(model['parts'], _signedCalls);
      final responses = [
        for (final content in contents)
          for (final part in content['parts'] as List)
            if (part['functionResponse'] != null)
              part['functionResponse'] as Map,
      ];
      expect(responses.map((r) => r['id']), ['native-a', 'native-b']);
      expect(responses.every((r) => r['name'] == 'web_search'), isTrue);
      expect(jsonEncode(responses), contains('Synthetic documentation'));
      expect(usage, hasLength(1));
      expect(usage.single.inputTokens, 15);
      expect(usage.single.outputTokens, 13);
      expect(usage.single.reasoningTokens, 5);
      expect(usage.single.cachedInputTokens, 4);

      // Completed tool exchanges remain transient; the next user turn uses the
      // persisted answer, not a stale function-call round from another request.
      await controller.sendMessage('继续解释上一条结论');
      expect(container.read(chatControllerProvider).requireValue.error, isNull);
      expect(adapter.bodies, hasLength(3));
      final nextContents = jsonEncode(adapter.bodies.last['contents']);
      expect(nextContents, contains('结论已确认'));
      expect(nextContents, isNot(contains('functionCall')));
      expect(nextContents, isNot(contains('signature-a')));
    },
  );

  test(
    'truncated Gemini function call is never executed by the chat controller',
    () async {
      final adapter = _Adapter((_) => [_candidate(_signedCalls, 'MAX_TOKENS')]);
      final search = _Search();
      final container = await _container(adapter, search, []);
      await container
          .read(chatControllerProvider.notifier)
          .sendMessage('请检索资料');
      final state = container.read(chatControllerProvider).requireValue;
      expect(state.error, isNotNull);
      expect(state.isStreaming, isFalse);
      expect(search.queries, isEmpty);
      expect(adapter.requests, hasLength(1));
    },
  );
}
