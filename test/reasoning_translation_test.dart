import 'dart:async';
import 'package:dio/dio.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/chat/thinking_timeline.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/reasoning_translation.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => SettingsState(
    profiles: [
      ProviderProfile(
        id: 'p',
        name: 'test',
        baseUrl: 'https://test.invalid',
        chatModel: 'model-a',
        reasonerModel: 'model-a',
        models: ['model-a', 'model-b'],
      ),
    ],
    activeProfileId: 'p',
    apiKey: 'test-key',
  );
}

class _Request {
  _Request(this.config, this.messages, this.token);
  final LlmConfig config;
  final List<LlmRequestMessage> messages;
  final CancelToken token;
  final chunks = StreamController<ChatChunk>();
}

class _Provider implements LlmProvider {
  final requests = <_Request>[];
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
    expect(tools, isNull);
    expect(thinking, false);
    expect(config.serverWebSearch, false);
    expect(config.allowReasoningRetry, false);
    final request = _Request(config, messages, cancelToken!);
    requests.add(request);
    return request.chunks.stream;
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Expected translation state was not reached');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Provider llm;
  late SharedPreferences prefs;
  ProviderContainer create() => ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      settingsControllerProvider.overrideWith(_Settings.new),
      llmProvider.overrideWithValue(llm),
    ],
  );
  ReasoningTranslationState current() => container.read(
    reasoningTranslationProvider,
  )[ReasoningTranslation.key('c', 'm')]!;
  Future<void> reply(int index, String value, {String finish = 'stop'}) async {
    llm.requests[index].chunks.add(
      ChatChunk(contentDelta: value, finishReason: finish),
    );
    await llm.requests[index].chunks.close();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
      providerApiKeyStorageKey('p'): 'test-key',
    });
    llm = _Provider();
    container = create();
    await container.read(settingsControllerProvider.future);
  });
  tearDown(() async {
    container.dispose();
    for (final request in llm.requests) {
      unawaited(request.chunks.close());
    }
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      {},
    );
  });

  test('Unicode boundaries and protected formulas/code survive unchanged', () {
    final unicode = '${'a' * 1499}👩‍💻x';
    final end = nextReasoningTranslationEnd(unicode, 0, flushTail: true);
    expect(end, 1499);
    const source =
        'Consider \$x^2+1\$ and ```cpp\nint n = 2;\n``` before computing.';
    final protected = ProtectedReasoningText(source);
    final restored = protected.restore(
      protected.text.replaceAll('Consider', '考虑'),
    );
    expect(restored, contains('\$x^2+1\$'));
    expect(restored, contains('```cpp\nint n = 2;\n```'));
    expect(() => protected.restore('lost placeholders'), throwsStateError);
    for (final source in [
      '```py\nprint("hello")',
      r'$$ x + y',
      r'\[ x + y',
      r'\( x + y',
      r'$ x + y',
    ]) {
      expect(
        nextReasoningTranslationEnd(
          source,
          0,
          flushTail: true,
          sourceComplete: false,
        ),
        0,
      );
    }
    expect(
      nextReasoningTranslationEnd(
        'Prefix ```py\ncode',
        0,
        flushTail: true,
        sourceComplete: false,
      ),
      7,
    );
  });

  test(
    'manual start only; append translates new prefix; cache survives reopen and restart',
    () async {
      final service = container.read(reasoningTranslationProvider.notifier);
      service.updateSource(
        conversationId: 'c',
        messageId: 'm',
        segments: ['First thought. Second thought.'],
        isStreaming: false,
      );
      await Future<void>.delayed(Duration.zero);
      expect(llm.requests, isEmpty);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['First thought.'],
        isStreaming: false,
      );
      await until(() => llm.requests.length == 1);
      await reply(0, '第一个想法。');
      await until(() => !current().isRunning);
      service.updateSource(
        conversationId: 'c',
        messageId: 'm',
        segments: ['First thought. Second thought.'],
        isStreaming: false,
      );
      await until(() => llm.requests.length == 2);
      expect(llm.requests[1].messages.last.content, ' Second thought.');
      await reply(1, '第二个想法。');
      await until(() => !current().isRunning);
      expect(
        current().textFor(0, 'First thought. Second thought.'),
        '第一个想法。 第二个想法。',
      );
      service.setVisible('c', 'm', false);
      service.setVisible('c', 'm', true);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['First thought. Second thought.'],
        isStreaming: false,
      );
      await until(() => !current().isRunning);
      expect(llm.requests.length, 2);
      await service.flushCache();
      container.dispose();
      container = create();
      await container.read(settingsControllerProvider.future);
      container
          .read(reasoningTranslationProvider.notifier)
          .start(
            conversationId: 'c',
            messageId: 'm',
            segments: ['First thought. Second thought.'],
            isStreaming: false,
          );
      await until(
        () =>
            container
                .read(reasoningTranslationProvider)[ReasoningTranslation.key(
                  'c',
                  'm',
                )]
                ?.translatedSegments
                .isNotEmpty ==
            true,
      );
      expect(llm.requests.length, 2);
      expect(
        current().textFor(0, 'First thought. Second thought.'),
        '第一个想法。 第二个想法。',
      );
    },
  );

  test(
    'model switch and explicit stop reject stale responses without cancelling primary work',
    () async {
      final mainToken = CancelToken();
      final service = container.read(reasoningTranslationProvider.notifier);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Source.'],
        isStreaming: false,
      );
      await until(() => llm.requests.length == 1);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Source.'],
        isStreaming: false,
        modelChoice: 'model-b',
      );
      await Future<void>.delayed(Duration.zero);
      expect(llm.requests[0].token.isCancelled, true);
      await reply(0, '过时译文');
      await until(() => llm.requests.length == 2);
      expect(llm.requests[1].config.model, 'model-b');
      service.stop('c', 'm');
      await reply(1, '停止后的译文');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(current().translatedSegments, isEmpty);
      expect(current().enabled, false);
      expect(mainToken.isCancelled, false);
      service.updateSource(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Source. appended'],
        isStreaming: false,
      );
      expect(llm.requests.length, 2);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Source.'],
        isStreaming: false,
        modelChoice: 'model-b',
      );
      await until(() => llm.requests.length == 3);
      await reply(2, '新译文');
      await until(() => !current().isRunning);
      expect(current().translatedSegments[0], '新译文');
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Source.'],
        isStreaming: false,
        modelChoice: 'model-a',
      );
      await until(() => llm.requests.length == 4);
      await reply(3, '模型A译文');
      await until(() => !current().isRunning);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Source.'],
        isStreaming: false,
        modelChoice: 'model-b',
      );
      await until(() => current().translatedSegments[0] == '新译文');
      expect(llm.requests.length, 4);
    },
  );

  test(
    'missing terminal marker and oversized output fail, cancel transport and never cache',
    () async {
      final service = container.read(reasoningTranslationProvider.notifier);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Translate me'],
        isStreaming: false,
      );
      await until(() => llm.requests.length == 1);
      llm.requests[0].chunks.add(const ChatChunk(contentDelta: '不完整'));
      await llm.requests[0].chunks.close();
      await until(() => current().error != null);
      expect(llm.requests[0].token.isCancelled, true);
      expect(current().translatedSegments, isEmpty);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: ['Translate me'],
        isStreaming: false,
      );
      await until(() => llm.requests.length == 2);
      llm.requests[1].chunks.add(ChatChunk(contentDelta: '中' * 16001));
      await until(() => current().error != null);
      expect(llm.requests[1].token.isCancelled, true);
      expect(current().translatedSegments, isEmpty);
      await service.flushCache();
      expect(prefs.getString(ReasoningTranslation.cacheStorageKey), isNull);
    },
  );

  test(
    'failed or reasoning-only translation is not cached, usage stays auxiliary, timeline immutable',
    () async {
      const original = 'First. Second.';
      final message = ChatMessage(
        role: MessageRole.assistant,
        content: 'answer',
        reasoning: original,
      );
      final activity = SearchActivity(
        kind: SearchActivityKind.mcp,
        query: 'tool',
        reasoningOffset: 7,
        reasoningOffsetRecorded: true,
      );
      final segments = buildThinkingTimeline(
        reasoning: message.reasoning,
        activities: [activity],
      );
      final texts = segments
          .where((s) => s.isReasoning)
          .map((s) => s.text!)
          .toList();
      final mainContext = [
        const LlmRequestMessage(role: MessageRole.user, content: 'main task'),
      ];
      container
          .read(workSessionInsightsProvider.notifier)
          .request('c', 'main', 'main-model', mainContext, []);
      final service = container.read(reasoningTranslationProvider.notifier);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: texts,
        isStreaming: false,
      );
      await until(() => llm.requests.length == 1);
      llm.requests[0].chunks.add(
        const ChatChunk(
          reasoningDelta: 'not translated content',
          finishReason: 'stop',
        ),
      );
      await llm.requests[0].chunks.close();
      await until(() => current().error != null);
      expect(current().translatedSegments, isEmpty);
      service.start(
        conversationId: 'c',
        messageId: 'm',
        segments: texts,
        isStreaming: false,
      );
      await until(() => llm.requests.length == 2);
      llm.requests[1].chunks.add(
        const ChatChunk(usage: LlmUsage(inputTokens: 10, outputTokens: 5)),
      );
      llm.requests[1].chunks.add(
        const ChatChunk(usage: LlmUsage(inputTokens: 10, outputTokens: 5)),
      );
      await reply(1, '第一。');
      await until(() => llm.requests.length == 3);
      await reply(2, '第二。');
      await until(() => !current().isRunning);
      expect(current().inputTokens, 10);
      expect(current().outputTokens, 5);
      expect(current().reportedUsageCount, 1);
      expect(message.reasoning, original);
      expect(activity.reasoningOffset, 7);
      final main = container.read(workSessionInsightsProvider)['c']!;
      expect(main.model, 'main-model');
      expect(main.messages.single.content, 'main task');
      service.stop('c', 'm');
      expect(current().textFor(0, texts[0]), '第一。');
      service.updateSource(
        conversationId: 'c',
        messageId: 'm',
        segments: ['${texts[0]} More.', texts[1]],
        isStreaming: true,
      );
      expect(current().textFor(0, '${texts[0]} More.'), '第一。 More.');
      expect(llm.requests.length, 3);
      final logs = container
          .read(workRuntimeLogsProvider.notifier)
          .exportConversation('c');
      expect(logs, contains('translation'));
      expect(logs, isNot(contains(original)));
      expect(logs, isNot(contains('not translated content')));
      await service.forgetConversation('c');
      expect(container.read(reasoningTranslationProvider), isEmpty);
      expect(prefs.getString(ReasoningTranslation.cacheStorageKey), '[]');
    },
  );
}
