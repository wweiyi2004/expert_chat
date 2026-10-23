import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart' show MessageRole, Conversation;
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_questions.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:expert_chat/state/work_processes.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:expert_chat/domain/workbench/agents/agent_instructions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Request {
  _Request(this.config, this.thinking, this.effort, this.token, this.messages);
  final LlmConfig config;
  final bool? thinking;
  final ReasoningEffort? effort;
  final CancelToken? token;
  final List<LlmRequestMessage> messages;
  final chunks = StreamController<ChatChunk>();
}

class _BarrierLlm implements LlmProvider {
  final requests = <_Request>[];
  final changes = StreamController<void>.broadcast(sync: true);
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
    final request = _Request(
      config,
      thinking,
      reasoningEffort,
      cancelToken,
      List.of(messages),
    );
    requests.add(request);
    changes.add(null);
    return request.chunks.stream;
  }

  Future<void> untilRequests(int count) async {
    if (requests.length >= count) return;
    await changes.stream.firstWhere((_) => requests.length >= count);
  }
}

class _BarrierRepo extends InMemoryRepo {
  Completer<void>? pendingSave;
  Completer<void>? saveEntered;

  @override
  Future<void> saveConversation(Conversation conversation) async {
    if (pendingSave case final pending?) {
      if (saveEntered?.isCompleted == false) saveEntered!.complete();
      await pending.future;
    }
    await super.saveConversation(conversation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _BarrierLlm llm;
  late _BarrierRepo repository;
  late AppDatabase db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    llm = _BarrierLlm();
    repository = _BarrierRepo();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        conversationRepositoryProvider.overrideWithValue(repository),
        settingsControllerProvider.overrideWith(FakeSettings.new),
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
        desktopWorkspaceHostProvider.overrideWithValue(
          stub.createDesktopWorkspaceHost(),
        ),
        llmProvider.overrideWithValue(llm),
      ],
    );
    await container.read(chatControllerProvider.future);
    container
        .read(chatControllerProvider.notifier)
        .applyComposerPrefs(
          searchMode: SearchMode.off,
          imageGenMode: ImageGenMode.off,
          reasoningEffort: ReasoningEffort.high,
        );
  });
  tearDown(() async {
    container.dispose();
    for (final request in llm.requests) {
      await request.chunks.close();
    }
    await llm.changes.close();
    await Future<void>.delayed(Duration.zero);
    await db.close();
  });

  test(
    'two live sessions survive navigation and cancelling A preserves B',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      final a = container.read(chatControllerProvider).requireValue.currentId!;
      final sendA = controller.sendMessage('session A');
      await llm.untilRequests(1);
      controller.newConversation(forceNew: true);
      final b = container.read(chatControllerProvider).requireValue.currentId!;
      final sendB = controller.sendMessage('session B');
      await llm.untilRequests(2);
      expect(controller.runningConversationIds, {a, b});
      expect(llm.requests[0].config.responseHeaderTimeout, isNull);
      expect(llm.requests[1].config.responseHeaderTimeout, isNull);

      llm.requests[0].chunks.add(const ChatChunk(contentDelta: 'A partial'));
      llm.requests[1].chunks.add(const ChatChunk(contentDelta: 'B complete'));
      await Future<void>.delayed(Duration.zero);
      controller.reportAppBackground(true);
      controller.reportChatVisible(false);
      await controller.selectConversation(a);
      await controller.stopAndWait(conversationId: a);
      expect(llm.requests[0].token!.isCancelled, isTrue);
      expect(llm.requests[1].token!.isCancelled, isFalse);
      expect(controller.isConversationRunning(b), isTrue);

      llm.requests[1].chunks.add(const ChatChunk(finishReason: 'stop'));
      await llm.requests[1].chunks.close();
      await sendA;
      expect(await sendB, isTrue);
      final state = container.read(chatControllerProvider).requireValue;
      expect(state.currentId, a);
      expect(
        state.conversations
            .firstWhere((c) => c.id == a)
            .activePath
            .last
            .content,
        'A partial',
      );
      expect(
        state.conversations
            .firstWhere((c) => c.id == b)
            .activePath
            .last
            .content,
        'B complete',
      );
      expect(state.runningConversationIds, isEmpty);
      expect(
        state.sessionCheckpoints[a]!.status,
        SessionExecutionStatus.cancelled,
      );
      expect(
        state.sessionCheckpoints[b]!.status,
        SessionExecutionStatus.completed,
      );
    },
  );

  test(
    'thinking and permissions queue until both tools in the batch finish',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('ask two necessary questions');
      await llm.untilRequests(1);
      final questionArrivals = <PendingWorkQuestion>[];
      final arrived = StreamController<PendingWorkQuestion>.broadcast(
        sync: true,
      );
      final subscription = container.listen(workQuestionsProvider, (_, next) {
        for (final question in next) {
          if (!questionArrivals.contains(question)) {
            questionArrivals.add(question);
            arrived.add(question);
          }
        }
      });
      addTearDown(() async {
        subscription.close();
        await arrived.close();
      });
      final firstQuestion = arrived.stream.first;
      llm.requests[0].chunks.add(
        ChatChunk(
          toolCalls: [
            for (var i = 0; i < 2; i++)
              ToolCall(
                index: i,
                id: 'question-$i',
                name: 'work_ask_user',
                argumentsJson: jsonEncode({
                  'questions': [
                    {
                      'id': 'q$i',
                      'question': 'Needed choice $i',
                      'required': true,
                    },
                  ],
                }),
              ),
          ],
        ),
      );
      llm.requests[0].chunks.add(const ChatChunk(finishReason: 'tool_calls'));
      await llm.requests[0].chunks.close();
      final first = await firstQuestion;
      expect(llm.requests.first.config.reasoningGuardEnabled, false);
      expect(
        llm.requests.first.config.responseHeaderTimeout,
        const Duration(seconds: 120),
      );
      final taskBudget = container
          .read(settingsControllerProvider)
          .requireValue
          .taskBudget;
      await container
          .read(settingsControllerProvider.notifier)
          .setTaskBudget(taskBudget.copyWith(workResponseTimeoutSeconds: 240));
      await container
          .read(settingsControllerProvider.notifier)
          .setWorkAgentInstructions('主代理新规则');
      await container
          .read(settingsControllerProvider.notifier)
          .setSubagentInstructions('子代理新规则');
      controller.toggleDeepThink();
      controller.setReasoningEffort(ReasoningEffort.low);
      await container
          .read(sessionPolicyProvider.notifier)
          .save(
            id,
            const SessionPolicy(
              network: false,
              approval: WorkApprovalMode.full,
            ),
          );
      expect(
        controller.pendingSessionConfigFor(id)!.labels,
        containsAll(['思考', '权限']),
      );
      expect(llm.requests.length, 1);
      expect(
        llm.requests[0].messages.any((m) => m.content.contains('主代理新规则')),
        isFalse,
      );
      final secondQuestion = arrived.stream.first;
      container.read(workQuestionsProvider.notifier).answer(first.id, {
        'q0': {'text': 'answer 0'},
      });
      final second = await secondQuestion;
      expect(controller.pendingSessionConfigFor(id), isNotNull);
      expect(llm.requests.length, 1);
      container.read(workQuestionsProvider.notifier).answer(second.id, {
        'q1': {'text': 'answer 1'},
      });
      await llm.untilRequests(2);
      expect(llm.requests[1].thinking, isTrue);
      expect(llm.requests[1].effort, ReasoningEffort.low);
      expect(llm.requests[1].config.reasoningGuardEnabled, false);
      expect(
        llm.requests[1].config.responseHeaderTimeout,
        const Duration(seconds: 240),
      );
      expect(
        llm.requests[1].messages
            .where((m) => m.content.startsWith(AgentInstructions.mainMarker))
            .single
            .content,
        contains('主代理新规则'),
      );
      expect(
        llm.requests[1].messages.any((m) => m.content.contains('子代理新规则')),
        isFalse,
      );
      expect(controller.pendingSessionConfigFor(id), isNull);
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'done', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, isTrue);
      final logs = container
          .read(workRuntimeLogsProvider.notifier)
          .forConversation(id);
      expect(
        logs
            .where((entry) => entry.status == 'awaiting_response')
            .map((entry) => entry.timeoutSeconds),
        [120, 240],
      );
      expect(
        logs.any((entry) => entry.phase == 'tool' && entry.status == 'started'),
        true,
      );
      expect(
        logs.any(
          (entry) => entry.phase == 'tool' && entry.status == 'completed',
        ),
        true,
      );
      final exported = container
          .read(workRuntimeLogsProvider.notifier)
          .exportConversation(id);
      expect(exported, isNot(contains('Needed choice')));
      expect(exported, isNot(contains('answer 0')));
    },
  );

  test(
    'background completion continues the same root without resetting its child quota',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('audit current workspace');
      await llm.untilRequests(1);
      final runtime = container.read(workAgentsProvider);
      final root = runtime.records.singleWhere((r) => r.external);
      final commandFinished = Completer<WorkProcessResult>();
      container
          .read(workProcessesProvider)
          .start(
            conversationId: id,
            taskId: root.taskId,
            command: 'finite audit',
            target: 'test',
            execute: (_, _) => commandFinished.future,
          );
      llm.requests[0].chunks.add(
        const ChatChunk(contentDelta: 'initial reply', finishReason: 'stop'),
      );
      await llm.requests[0].chunks.close();
      await sent;
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .sessionCheckpoints[id]!
            .status,
        SessionExecutionStatus.waiting,
      );
      root.childrenCreated = 3;
      commandFinished.complete(
        const WorkProcessResult(exitCode: 0, output: 'audit complete'),
      );
      await llm.untilRequests(2);
      expect(runtime.records.where((r) => r.external).length, 1);
      expect(runtime.records.singleWhere((r) => r.external).id, root.id);
      expect(root.childrenCreated, 3);
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'combined report', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      for (var i = 0; i < 100 && controller.isConversationRunning(id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(controller.isConversationRunning(id), isFalse);
      expect(root.rounds, 2);
      expect(root.output, 'combined report');
    },
  );

  test(
    'completed tasks ignore late events and errors can be dismissed',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('finish work');
      await llm.untilRequests(1);
      final root = container
          .read(workAgentsProvider)
          .records
          .singleWhere((r) => r.external);
      llm.requests[0].chunks.add(
        const ChatChunk(contentDelta: 'done', finishReason: 'stop'),
      );
      await llm.requests[0].chunks.close();
      await sent;
      controller.enqueueSessionEvent(
        conversationId: id,
        eventId: 'late',
        taskId: root.taskId,
        content: 'late service exit',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(llm.requests.length, 1);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .sessionCheckpoints[id]!
            .status,
        SessionExecutionStatus.completed,
      );

      final failed = controller.sendMessage('request that fails');
      await llm.untilRequests(2);
      llm.requests[1].chunks.addError(StateError('network unavailable'));
      await llm.requests[1].chunks.close();
      await failed;
      expect(
        container.read(chatControllerProvider).requireValue.error,
        isNotNull,
      );
      controller.dismissError(conversationId: id);
      final after = container.read(chatControllerProvider).requireValue;
      expect(after.error, isNull);
      expect(after.retryOperation, isNull);
      expect(
        after.sessionCheckpoints[id]!.status,
        SessionExecutionStatus.failed,
      );
      expect(llm.requests.length, 2);
    },
  );

  test(
    'dismissing failure during persistence does not complete or reopen a waiting task',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('build then report');
      await llm.untilRequests(1);
      final root = container
          .read(workAgentsProvider)
          .records
          .singleWhere((r) => r.external);
      final commandFinished = Completer<WorkProcessResult>();
      container
          .read(workProcessesProvider)
          .start(
            conversationId: id,
            taskId: root.taskId,
            command: 'build',
            target: 'test',
            execute: (_, _) => commandFinished.future,
          );
      repository.pendingSave = Completer<void>();
      repository.saveEntered = Completer<void>();
      llm.requests[0].chunks.addError(StateError('connection failed'));
      await repository.saveEntered!.future;
      expect(controller.isConversationRunning(id), true);
      expect(
        container.read(chatControllerProvider).requireValue.error,
        isNotNull,
      );
      controller.dismissError(conversationId: id);
      expect(container.read(chatControllerProvider).requireValue.error, isNull);
      repository.pendingSave!.complete();
      await llm.requests[0].chunks.close();
      await sent;
      final state = container.read(chatControllerProvider).requireValue;
      expect(state.error, isNull);
      expect(
        state.sessionCheckpoints[id]!.status,
        SessionExecutionStatus.failed,
      );
      commandFinished.complete(const WorkProcessResult(exitCode: 0));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(llm.requests.length, 1);
      expect(container.read(chatControllerProvider).requireValue.error, isNull);
    },
  );

  test(
    'stopping a waiting task prevents command completion from restarting it',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('wait for build');
      await llm.untilRequests(1);
      final root = container
          .read(workAgentsProvider)
          .records
          .singleWhere((r) => r.external);
      final commandFinished = Completer<WorkProcessResult>();
      container
          .read(workProcessesProvider)
          .start(
            conversationId: id,
            taskId: root.taskId,
            command: 'build',
            target: 'test',
            execute: (_, _) => commandFinished.future,
          );
      llm.requests[0].chunks.add(
        const ChatChunk(contentDelta: 'waiting', finishReason: 'stop'),
      );
      await llm.requests[0].chunks.close();
      await sent;
      controller.stop(conversationId: id);
      commandFinished.complete(const WorkProcessResult(exitCode: 0));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(llm.requests.length, 1);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .sessionCheckpoints[id]!
            .status,
        SessionExecutionStatus.cancelled,
      );
    },
  );

  test(
    'main and child instruction settings persist and remain independent',
    () async {
      final settings = container.read(settingsControllerProvider.notifier);
      await settings.setWorkAgentInstructions('MAIN: plan and summarize');
      await settings.setSubagentInstructions(
        'CHILD: inspect and report evidence',
      );
      final prefs = container.read(sharedPrefsProvider);
      expect(
        prefs.getString('workAgentInstructions'),
        'MAIN: plan and summarize',
      );
      expect(
        prefs.getString('subagentInstructions'),
        'CHILD: inspect and report evidence',
      );
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final sent = controller.sendMessage('audit');
      await llm.untilRequests(1);
      expect(
        llm.requests.single.messages.any((m) => m.content.contains('MAIN:')),
        isTrue,
      );
      expect(
        llm.requests.single.messages.any((m) => m.content.contains('CHILD:')),
        isFalse,
      );
      final root = container
          .read(workAgentsProvider)
          .records
          .singleWhere((r) => r.external);
      final child = root.environment.prepareMessages!(
        [
          const LlmRequestMessage(
            role: MessageRole.user,
            content: 'child assignment',
          ),
        ],
        root.environment.config,
        'child-context',
      );
      expect(child.any((m) => m.content.contains('CHILD:')), isTrue);
      expect(child.any((m) => m.content.contains('MAIN:')), isFalse);
      await settings.setWorkAgentInstructions('');
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .subagentInstructions,
        'CHILD: inspect and report evidence',
      );
      llm.requests.single.chunks.add(
        const ChatChunk(contentDelta: 'done', finishReason: 'stop'),
      );
      await llm.requests.single.chunks.close();
      expect(await sent, isTrue);
    },
  );
}
