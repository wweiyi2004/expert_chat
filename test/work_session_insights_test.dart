import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/state/work_session_insights.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test(
    'request categories retain auxiliary usage without changing the task model',
    () {
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final controller = container.read(workSessionInsightsProvider.notifier);
      const auxiliary = LlmConfig(
        baseUrl: 'https://synthetic.invalid',
        apiKey: '',
        model: 'title-model',
      );
      controller.request('a', 'main', 'task-model', [], []);
      controller.auxiliaryRequest(
        'a',
        'title',
        auxiliary,
        kind: WorkRequestKind.title,
      );
      controller.auxiliaryRequest('a', 'review', auxiliary);
      controller.auxiliaryRequest(
        'a',
        'retry',
        auxiliary,
        kind: WorkRequestKind.task,
      );
      controller.route('a', 'title', auxiliary);
      const usage = LlmUsage(
        inputTokens: 10,
        outputTokens: 2,
        cost: .01,
        currency: 'USD',
      );
      for (final id in ['main', 'title', 'review', 'retry']) {
        controller.usage('a', id, usage);
      }
      final state = container.read(workSessionInsightsProvider)['a']!;
      expect(state.model, 'task-model');
      expect(state.countRequests(WorkRequestKind.task), 2);
      expect(state.countRequests(WorkRequestKind.title), 1);
      expect(state.countRequests(WorkRequestKind.auxiliary), 1);
      expect(state.inputTokens, 40);
      expect(state.cost, closeTo(.04, .000001));
    },
  );
  test(
    'usage is isolated per conversation, duplicate terminal chunks replace and missing usage stays unknown',
    () {
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final controller = container.read(workSessionInsightsProvider.notifier);
      final messages = [
        const LlmRequestMessage(role: MessageRole.user, content: '原始请求'),
      ];
      controller.request('a', 'r1', 'model', messages, []);
      messages.clear();
      const usage = LlmUsage(
        inputTokens: 100,
        outputTokens: 20,
        cachedInputTokens: 50,
        cacheReported: true,
        cost: .02,
        currency: 'USD',
      );
      controller.usage('a', 'r1', usage);
      controller.usage('a', 'r1', usage);
      final first = container.read(workSessionInsightsProvider)['a']!;
      expect(first.messages.single.content, '原始请求');
      expect(first.inputTokens, 100);
      expect(first.cachedTokens, 50);
      expect(first.cost, .02);
      controller.request('b', 'r2', 'model', [], []);
      expect(container.read(workSessionInsightsProvider)['b']!.cost, isNull);
      controller.request('a', 'r3', 'model', [], []);
      final pending = container.read(workSessionInsightsProvider)['a']!;
      expect(pending.cacheComplete, isFalse);
      expect(pending.cost, isNull);
      controller.usage(
        'a',
        'r3',
        const LlmUsage(
          inputTokens: 50,
          outputTokens: 10,
          cacheReported: true,
          cost: .03,
          currency: 'USD',
        ),
      );
      final complete = container.read(workSessionInsightsProvider)['a']!;
      expect(complete.cacheComplete, isTrue);
      expect(complete.inputTokens, 150);
      expect(complete.cost, closeTo(.05, .00001));
    },
  );
  test(
    'cache zero is distinct from missing and DeepSeek hit counters are parsed',
    () {
      final absent = LlmUsage.fromChatCompletions({'prompt_tokens': 100});
      final zero = LlmUsage.fromChatCompletions({
        'prompt_tokens': 100,
        'prompt_tokens_details': {'cached_tokens': 0},
      });
      final hit = LlmUsage.fromChatCompletions({
        'prompt_tokens': 100,
        'prompt_tokens_details': {},
        'prompt_cache_hit_tokens': 80,
      });
      expect(absent!.cacheReported, isFalse);
      expect(zero!.cacheReported, isTrue);
      expect(hit!.cachedInputTokens, 80);
      expect(hit.cacheReported, isTrue);
      expect(
        const WorkSessionInsights(
          requests: {'r': LlmUsage(inputTokens: 1, outputTokens: 1, cost: 1)},
        ).cost,
        isNull,
      );
    },
  );
}
