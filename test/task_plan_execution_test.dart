import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/task_plans.dart';
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';
import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _PlanModel implements LlmProvider {
  _PlanModel({this.updateProgress = false});
  final bool updateProgress;
  int requests = 0;
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
    if (config.maxOutputTokens == 64) {
      yield const ChatChunk(contentDelta: '测试计划', finishReason: 'stop');
      return;
    }
    requests++;
    if (requests == 1) {
      yield ChatChunk(
        toolCalls: [
          ToolCall(
            index: 0,
            id: 'plan-call',
            name: 'work_set_plan',
            argumentsJson: jsonEncode({
              'expected_revision': 0,
              'body':
                  'Inspect the existing parser, then implement the requested change.',
              'steps': ['Inspect', 'Implement'],
            }),
          ),
        ],
        finishReason: 'tool_calls',
      );
    } else if (updateProgress && requests == 3) {
      final current = messages.lastWhere(
        (m) => m.content.startsWith('【当前计划，用户控制版本】'),
      );
      final plan = jsonDecode(current.content.split('\n')[1]) as Map;
      yield ChatChunk(
        toolCalls: [
          for (var i = 0; i < (plan['steps'] as List).length; i++)
            ToolCall(
              index: i,
              id: 'progress-$i',
              name: 'work_plan_progress',
              argumentsJson: jsonEncode({
                'revision': plan['revision'],
                'step_id': plan['steps'][i]['id'],
                'status': 'completed',
              }),
            ),
        ],
        finishReason: 'tool_calls',
      );
    } else {
      yield const ChatChunk(
        contentDelta: 'Approved plan processed',
        finishReason: 'stop',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final updateProgress in [false, true]) {
    test(
      'plan approval resumes and final progress reconciliation is bounded: $updateProgress',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase(NativeDatabase.memory()),
            model = _PlanModel(updateProgress: updateProgress);
        final repo = InMemoryRepo()
          ..store = [
            Conversation(id: 'plan-session', workMode: true, title: 'plan'),
          ];
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            appDatabaseProvider.overrideWithValue(db),
            conversationRepositoryProvider.overrideWithValue(repo),
            desktopWorkspaceHostProvider.overrideWithValue(
              stub.createDesktopWorkspaceHost(),
            ),
            settingsControllerProvider.overrideWith(FakeSettings.new),
            llmProvider.overrideWithValue(model),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await Future<void>.delayed(Duration.zero);
          await db.close();
        });
        await container.read(chatControllerProvider.future);
        final controller = container.read(chatControllerProvider.notifier);
        await controller.selectConversation('plan-session');
        await container
            .read(sessionPolicyProvider.notifier)
            .save(
              'plan-session',
              const SessionPolicy(planOnly: true, network: false),
            );
        final ready = Completer<TaskPlan>();
        final subscription = container.listen(taskPlansProvider, (_, plans) {
          if (plans['plan-session'] case final plan?) {
            if (!ready.isCompleted) ready.complete(plan);
          }
        });
        addTearDown(subscription.close);
        final sending = controller.sendMessage('Repair the parser');
        final plan = await ready.future.timeout(const Duration(seconds: 10));
        final root = controller.taskSnapshotFor('plan-session')!['rootId'];
        expect(plan.taskId, root);
        expect(plan.status, TaskPlanStatus.awaitingApproval);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(model.requests, 1);
        expect(controller.isConversationRunning('plan-session'), isTrue);
        final revised = await container
            .read(taskPlansProvider.notifier)
            .comment(
              'plan-session',
              plan.revision,
              'Preserve current behavior',
            );
        await expectLater(
          controller.approveTaskPlan(
            'plan-session',
            plan.revision,
            plan.contentHash,
          ),
          throwsStateError,
        );
        expect(model.requests, 1);
        await controller.approveTaskPlan(
          'plan-session',
          revised.revision,
          revised.contentHash,
        );
        expect(await sending.timeout(const Duration(seconds: 10)), isTrue);
        expect(controller.taskSnapshotFor('plan-session')!['rootId'], root);
        expect(model.requests, updateProgress ? 4 : 3);
        if (updateProgress) {
          expect(
            container
                .read(taskPlansProvider)['plan-session']!
                .steps
                .every((s) => s.status == PlanStepStatus.completed),
            isTrue,
          );
        } else {
          expect(
            container
                .read(chatControllerProvider)
                .requireValue
                .current!
                .messages
                .last
                .content,
            contains('待办清单仍有'),
          );
        }
        await container
            .read(sessionPolicyProvider.notifier)
            .save('plan-session', const SessionPolicy(network: false));
        expect(await controller.sendMessage('A separate task'), isTrue);
        expect(
          controller.taskSnapshotFor('plan-session')!['rootId'],
          isNot(root),
        );
        await expectLater(
          controller.approveTaskPlan(
            'plan-session',
            revised.revision,
            revised.contentHash,
          ),
          throwsStateError,
        );
        await expectLater(
          ControllerBridgeBackend(container).invoke('plan.cancel', {
            'session_id': 'plan-session',
            'revision': revised.revision,
          }),
          throwsA(
            isA<BridgeFailure>().having(
              (failure) => failure.code,
              'code',
              'conflict',
            ),
          ),
        );
      },
    );
  }
}
