import 'dart:convert';
import 'package:expert_chat/data/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/llm_http_errors.dart';
import 'package:expert_chat/domain/llm/prioritized_llm_provider.dart';
import 'package:expert_chat/domain/llm/model_route_diagnostics.dart';
import 'package:expert_chat/domain/tools/math/math_toolkit.dart';
import 'package:expert_chat/domain/workbench/agents/task_supervisor.dart';
import 'package:expert_chat/state/role_evolution.dart';
import 'package:expert_chat/data/subagent_role.dart';
import 'package:expert_chat/domain/llm/model_group_llm_provider.dart';
import 'package:expert_chat/domain/tools/task_tool_registry.dart';
import 'package:expert_chat/state/controlled_browser.dart';

class FakeLlm implements LlmProvider {
  FakeLlm(this.reply);
  final Stream<ChatChunk> Function(LlmConfig) reply;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) => reply(config);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = LlmConfig(
    baseUrl: 'http://localhost',
    apiKey: 'not-used',
    model: 'model',
  );
  test(
    'explicit model group fails over only before output and never continuation',
    () async {
      final attempted = <String>[];
      final provider = ModelGroupLlmProvider(
        FakeLlm((selected) async* {
          attempted.add(selected.model);
          if (selected.model == 'model') {
            throw const LlmHttpException('quota', statusCode: 429);
          }
          yield const ChatChunk(contentDelta: 'fallback', finishReason: 'stop');
        }),
      );
      final grouped = config.copyWith(
        modelFallbacks: [config.copyWith(model: 'backup')],
      );
      expect(
        (await provider.streamChat(config: grouped, messages: []).toList())
            .single
            .contentDelta,
        'fallback',
      );
      expect(attempted, ['model', 'backup']);
      attempted.clear();
      await expectLater(
        provider
            .streamChat(
              config: grouped,
              messages: [
                const LlmRequestMessage(
                  role: MessageRole.tool,
                  content: 'already executed',
                ),
              ],
            )
            .toList(),
        throwsA(isA<LlmHttpException>()),
      );
      expect(attempted, ['model']);
      attempted.clear();
      final partial = ModelGroupLlmProvider(
        FakeLlm((selected) async* {
          attempted.add(selected.model);
          yield const ChatChunk(contentDelta: 'partial');
          throw const LlmHttpException('late', statusCode: 503);
        }),
      );
      await expectLater(
        partial.streamChat(config: grouped, messages: []).toList(),
        throwsA(isA<LlmHttpException>()),
      );
      expect(attempted, ['model']);
    },
  );
  test(
    'registry discovery does not enable, permission waits for full boundary and revocation wins',
    () async {
      const read = ToolSpec(
        name: 'read',
        description: 'read data',
        parameters: {},
      );
      const math = ToolSpec(
        name: 'math_calculate',
        description: 'math',
        parameters: {},
      );
      final registry = TaskToolRegistry(
        catalog: [read, math],
        initiallyActive: {'read'},
      );
      expect(registry.search('math')['tools'], hasLength(1));
      expect(
        registry.visibleTools.map((t) => t.name),
        isNot(contains('math_calculate')),
      );
      await registry.request(['math_calculate'], authorize: (_) async => true);
      expect(
        registry.visibleTools.map((t) => t.name),
        isNot(contains('math_calculate')),
      );
      expect(registry.applyBoundary(), ['math_calculate']);
      registry.updateCatalog([read]);
      expect(
        registry.visibleTools.map((t) => t.name),
        isNot(contains('math_calculate')),
      );
      expect(
        (await registry.request(['admin'], authorize: (_) async => true))['ok'],
        false,
      );
    },
  );
  test(
    'controlled browser isolates conversation/agent, takeover and feedback consumed once',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final browser = container.read(controlledBrowserProvider.notifier);
      browser.observe(
        conversation: 'a',
        server: 'browser',
        agent: 'child1',
        tool: 'snapshot',
        text: 'A',
      );
      browser.observe(
        conversation: 'b',
        server: 'browser',
        agent: 'child1',
        tool: 'snapshot',
        text: 'B',
      );
      browser.takeover('a', true);
      expect(browser.takenOver('a'), true);
      expect(browser.takenOver('b'), false);
      browser.addFeedback('a', 'ref=e5');
      expect(browser.consumeFeedback('b'), isEmpty);
      expect(browser.consumeFeedback('a'), ['ref=e5']);
      expect(browser.consumeFeedback('a'), isEmpty);
      browser.clear('a');
      expect(
        container
            .read(controlledBrowserProvider)
            .observations
            .values
            .single
            .text,
        'B',
      );
    },
  );
  SupervisorSnapshot snapshot(String version, int round) => SupervisorSnapshot(
    taskId: 'task',
    version: version,
    round: round,
    trigger: 'repeated_failure',
    goal: 'finish',
    availableTools: ['read'],
    allowedModels: ['model'],
  );
  test(
    'supervisor defaults off, bounded interventions and stale rejection',
    () async {
      final supervisor = TaskSupervisor();
      final backend = FakeLlm((_) async* {
        yield ChatChunk(
          contentDelta: jsonEncode({
            'advice': 'Inspect output',
            'evidence': 'two failures',
            'requested_tools': ['read'],
            'suggested_model': '',
          }),
          finishReason: 'stop',
          usage: const LlmUsage(inputTokens: 100, outputTokens: 20),
        );
      });
      final token = CancelToken();
      expect(
        await supervisor.review(
          settings: const SupervisorConfig(),
          snapshot: snapshot('v1', 0),
          provider: backend,
          config: config,
          cancelToken: token,
        ),
        isNull,
      );
      const enabled = SupervisorConfig(
        enabled: true,
        model: 'model',
        maxReviews: 1,
      );
      await supervisor.review(
        settings: enabled,
        snapshot: snapshot('v1', 0),
        provider: backend,
        config: config,
        cancelToken: token,
      );
      expect(
        supervisor.takeAtBoundary(
          taskId: 'task',
          version: 'v2',
          completedRound: 0,
        ),
        isNull,
      );
      expect(supervisor.metrics.stale, 1);
      expect(supervisor.metrics.reportedInputTokens, 100);
      expect(supervisor.shouldReview(enabled, snapshot('v3', 9)), isFalse);
      token.cancel();
    },
  );
  test(
    'supervisor rejects unavailable tools and records no false intervention',
    () async {
      final supervisor = TaskSupervisor();
      final token = CancelToken();
      final backend = FakeLlm((_) async* {
        yield const ChatChunk(
          contentDelta:
              '{"advice":"run","evidence":"x","requested_tools":["admin_shell"],"suggested_model":""}',
        );
      });
      expect(
        await supervisor.review(
          settings: const SupervisorConfig(enabled: true, model: 'model'),
          snapshot: snapshot('v1', 0),
          provider: backend,
          config: config,
          cancelToken: token,
        ),
        isNull,
      );
      expect(supervisor.metrics.interventions, 0);
      expect(supervisor.metrics.failed, 1);
      token.cancel();
    },
  );
  test('same-model failover records status and never switches model', () async {
    final diagnostics = ModelRouteDiagnostics();
    final attempts = <String>[];
    final delegate = FakeLlm((selected) async* {
      attempts.add(selected.profileId!);
      if (selected.profileId == 'first') {
        throw const LlmHttpException('limited', statusCode: 429);
      }
      yield const ChatChunk(contentDelta: 'ok');
    });
    final provider = PrioritizedLlmProvider(
      delegate: delegate,
      credentials: (c) async => c,
      diagnostics: diagnostics,
      candidates: (c) async => [
        c.copyWith(profileId: 'first'),
        c.copyWith(model: 'other', profileId: 'wrong'),
        c.copyWith(profileId: 'second'),
      ],
    );
    final chunks = await provider
        .streamChat(config: config, messages: [])
        .toList();
    expect(chunks.last.contentDelta, 'ok');
    expect(attempts, ['first', 'second']);
    expect(diagnostics.events.first.statusCode, 429);
  });
  test(
    'role candidate requires real version evidence and revision invalidates it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final roles = container.read(roleEvolutionProvider.notifier);
      final search = roles.search(
        task: 'statistics',
        roles: SubagentRole.defaults(),
        availableTools: ['math_calculate'],
      );
      final candidate = await roles.propose(
        searchId: search['search_id'] as String,
        name: 'Statistics',
        when: 'data analysis',
        instructions: 'Compute exact statistics',
        model: 'model',
        requiredTools: ['math_calculate'],
        source: 'existing library search',
      );
      expect(candidate.verified, isFalse);
      await roles.recordEvidence(
        id: candidate.role.id,
        version: 1,
        taskId: 'trial',
        artifactVersions: {'report': 'hash1'},
        success: true,
        summary: 'verified calculation',
        acceptance: 'Independent exact value matches expected result',
      );
      expect(container.read(roleEvolutionProvider).single.verified, isTrue);
      await roles.revise(
        candidate.role.id,
        candidate.role.copyWith(instructions: 'changed'),
      );
      expect(container.read(roleEvolutionProvider).single.verified, isFalse);
      expect(container.read(roleEvolutionProvider).single.history.length, 1);
      await roles.rollback(candidate.role.id, 1);
      expect(container.read(roleEvolutionProvider).single.version, 3);
      expect(
        container.read(roleEvolutionProvider).single.role.instructions,
        'Compute exact statistics',
      );
    },
  );
  test(
    'math cancellation does not start calculation or return fabricated output',
    () async {
      final token = CancelToken()..cancel('stop');
      await expectLater(
        MathToolkit().execute({
          'operation': 'exact',
          'expression': '1+1',
        }, cancelToken: token),
        throwsA(isA<DioException>()),
      );
    },
  );
  test(
    'actual math worker returns exact calculation and original domain',
    () async {
      final result = await MathToolkit().execute({
        'operation': 'verify',
        'expression': 'x/x',
        'rhs': '1',
      });
      expect(result['ok'], true);
      expect((result['result'] as Map)['original_domain_exclusions'], [
        'x != 0',
      ]);
      expect((result['result'] as Map)['conditional'], true);
    },
  );
}
