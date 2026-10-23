import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/data/subagent_role.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/subagent_role_router.dart';
import 'package:expert_chat/domain/workbench/agents/work_agent_runtime.dart';

class _Classifier implements LlmProvider {
  _Classifier(this.output);
  final String output;
  List<LlmRequestMessage> seen = [];
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
    seen = messages;
    expect(tools, isNull);
    expect(thinking, false);
    yield ChatChunk(contentDelta: output, finishReason: 'stop');
  }
}

void main() {
  const config = LlmConfig(
    baseUrl: 'https://test.invalid',
    apiKey: 'test',
    model: 'small-model',
  );
  const roles = [
    SubagentRole(
      id: 'general',
      name: '通用',
      when: '其他',
      instructions: 'general only',
    ),
    SubagentRole(
      id: 'review',
      name: '审查',
      when: '找代码缺陷',
      instructions: 'review only',
      model: 'review-model',
    ),
    SubagentRole(
      id: 'disabled',
      name: '禁用',
      when: '全部',
      instructions: 'disabled',
      enabled: false,
    ),
  ];
  test(
    'model classifies the task and role binding stays inside model pool',
    () async {
      final provider = _Classifier(
        '{"role_id":"review","model":"outside-pool","reason":"检查缺陷"}',
      );
      final selected = await const SubagentRoleRouter().choose(
        provider: provider,
        config: config,
        task: '审计代码',
        roles: roles,
        allowedModels: ['small-model', 'review-model'],
        cancelToken: CancelToken(),
      );
      expect(selected.role.id, 'review');
      expect(selected.model, 'review-model');
      expect(provider.seen.last.content, isNot(contains('disabled')));
      expect(provider.seen.last.content, isNot(contains('review only')));
    },
  );
  test(
    'invalid classification falls back to an enabled role and allowed model',
    () async {
      final selected = await const SubagentRoleRouter().choose(
        provider: _Classifier('{"role_id":"invented","model":"outside"}'),
        config: config,
        task: 'task',
        roles: roles,
        allowedModels: ['small-model', 'review-model'],
        cancelToken: CancelToken(),
      );
      expect(selected.role.id, 'general');
      expect(selected.model, 'small-model');
      expect(selected.reason, contains('回退'));
    },
  );
  test(
    'legacy child prompt migrates to general role without overwriting specialist prompts',
    () {
      final defaults = SubagentRole.defaults('my old prompt');
      final restored = SubagentRole.decode(
        jsonEncode(defaults.map((r) => r.toJson()).toList()),
      )!;
      expect(restored.first.instructions, 'my old prompt');
      expect(
        restored.firstWhere((r) => r.id == 'review').instructions,
        isNot('my old prompt'),
      );
    },
  );
  test(
    'role instructions and choice survive followup without reclassification',
    () async {
      final runtime = WorkAgentRuntime();
      addTearDown(runtime.dispose);
      final provider = _RoleWorker();
      var choices = 0;
      final env = WorkAgentEnvironment(
        provider: provider,
        config: config,
        tools: const [],
        modelPool: const [WorkAgentModelOption('review-model')],
        roles: roles,
        executeTool: (_, _, _, _) async => 'ok',
        resolveModel: (m, c) async => c.copyWith(model: m),
        selectRole: (_, _, _) async {
          choices++;
          return SubagentAssignment(
            role: roles[1],
            model: 'review-model',
            reason: '审查任务',
          );
        },
      );
      final root = runtime.registerRoot(
        conversationId: 'c',
        taskId: 't',
        task: 'root',
        environment: env,
      );
      final id = runtime.spawn(parentId: root, task: 'audit');
      Future<void> completed() async {
        for (var i = 0; i < 100 && !runtime.record(id)!.terminal; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }

      await completed();
      expect(runtime.record(id)!.role?.name, '审查');
      expect(
        provider.last.any((m) => m.content.contains('review only')),
        isTrue,
      );
      runtime.followup(id, 'continue');
      await completed();
      expect(choices, 1);
      expect(runtime.record(id)!.model, 'review-model');
    },
  );
}

class _RoleWorker implements LlmProvider {
  List<LlmRequestMessage> last = [];
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
    last = messages;
    yield const ChatChunk(contentDelta: 'review result', finishReason: 'stop');
  }
}
