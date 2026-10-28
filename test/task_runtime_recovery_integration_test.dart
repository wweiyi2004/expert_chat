import 'package:expert_chat/state/role_evolution.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:expert_chat/core/desktop_providers.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart' show AppDatabase;
import 'package:expert_chat/data/models.dart' show Conversation;
import 'package:expert_chat/domain/desktop/workspace_host_stub.dart' as stub;
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/domain/desktop/workspace_host.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:expert_chat/state/work_processes.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/platform/preferences.dart';

import 'widget_test.dart' show FakeSettings, InMemoryRepo;

class _Request {
  _Request(
    this.config,
    this.thinking,
    this.effort,
    this.token,
    this.messages, [
    this.tools = const [],
  ]);
  final List<ToolSpec> tools;
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
      List.of(tools ?? const []),
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

class _GatedRoleEvolution extends RoleEvolutionController {
  Completer<void>? evidenceGate;
  Completer<void>? evidenceEntered;
  @override
  Future<void> recordEvidence({
    required String id,
    required int version,
    required String taskId,
    required Map<String, String> artifactVersions,
    required bool success,
    required String summary,
    String resultHash = '',
    String acceptance = '',
  }) async {
    evidenceEntered?.complete();
    await evidenceGate?.future;
    await super.recordEvidence(
      id: id,
      version: version,
      taskId: taskId,
      artifactVersions: artifactVersions,
      success: success,
      summary: summary,
      resultHash: resultHash,
      acceptance: acceptance,
    );
  }
}

class _BarrierRepo extends InMemoryRepo {
  bool failEventSave = false;
  Completer<void>? pendingSave;
  Completer<void>? saveEntered;

  @override
  Future<void> saveConversation(Conversation conversation) async {
    if (failEventSave &&
        conversation.messages.any(
          (m) => m.content.contains('INLINE_DURABLE_EVENT'),
        )) {
      throw StateError('fixture event persistence failure');
    }
    if (pendingSave case final pending?) {
      if (saveEntered?.isCompleted == false) saveEntered!.complete();
      await pending.future;
    }
    await super.saveConversation(conversation);
  }
}

class _ControllableSettings extends FakeSettings {
  void fixtureKey(String value) =>
      state = AsyncData(state.requireValue.copyWith(apiKey: value));
}

class _CountingHost implements DesktopWorkspaceHost {
  int defaultCalls = 0;
  @override
  bool get supported => true;
  @override
  Future<DesktopWorkspace> defaultWorkspace() async {
    defaultCalls++;
    return const DesktopWorkspace(
      id: 'fixture-workspace',
      name: 'fixture',
      root: 'E:/fixture',
      scopes: [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No native process in fixture');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _BarrierLlm llm;
  late _BarrierRepo repository;
  late AppDatabase db;
  Future<void> createContainer() async {
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        conversationRepositoryProvider.overrideWithValue(repository),
        settingsControllerProvider.overrideWith(_ControllableSettings.new),
        roleEvolutionProvider.overrideWith(_GatedRoleEvolution.new),
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
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    llm = _BarrierLlm();
    repository = _BarrierRepo();
    await createContainer();
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
    'ordinary chat never creates workspace or acceptance; work captures target',
    () async {
      final host = _CountingHost();
      container.dispose();
      container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          conversationRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWith(_ControllableSettings.new),
          roleEvolutionProvider.overrideWith(_GatedRoleEvolution.new),
          sharedPrefsProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          desktopWorkspaceHostProvider.overrideWithValue(host),
          llmProvider.overrideWithValue(llm),
        ],
      );
      await container.read(chatControllerProvider.future);
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('ordinary chat');
      await llm.untilRequests(1);
      llm.requests[0].chunks.add(
        const ChatChunk(contentDelta: 'ordinary answer', finishReason: 'stop'),
      );
      await llm.requests[0].chunks.close();
      expect(await sent, true);
      expect(host.defaultCalls, 0);
      expect(controller.taskSnapshotFor(id), isNull);
      expect(
        (await SharedPreferences.getInstance()).getString('taskAcceptance.v1'),
        isNull,
      );
      controller.newConversation(workMode: true, forceNew: true);
      final workId = container
          .read(chatControllerProvider)
          .requireValue
          .currentId!;
      await controller.sendMessage('work fixture');
      expect(host.defaultCalls, greaterThan(0));
      expect(
        (controller.taskSnapshotFor(workId)!['target'] as Map)['root'],
        'E:/fixture',
      );
    },
  );

  for (final saveFails in [false, true]) {
    test(
      'inline event stays on assistant branch; persistence failure=$saveFails',
      () async {
        var controller = container.read(chatControllerProvider.notifier);
        controller.newConversation(workMode: true, forceNew: true);
        final id = container
            .read(chatControllerProvider)
            .requireValue
            .currentId!;
        final sent = controller.sendMessage('fixture inline goal');
        await llm.untilRequests(1);
        final root = container
            .read(workAgentsProvider)
            .records
            .singleWhere((r) => r.external);
        repository.failEventSave = saveFails;
        controller.enqueueSessionEvent(
          conversationId: id,
          eventId: 'inline-event',
          taskId: root.taskId,
          content: 'INLINE_DURABLE_EVENT',
        );
        llm.requests[0].chunks.add(
          const ChatChunk(
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'history',
                name: 'work_history',
                argumentsJson: '{}',
              ),
            ],
            finishReason: 'tool_calls',
          ),
        );
        await llm.requests[0].chunks.close();
        if (saveFails) {
          await sent;
          expect(llm.requests.length, 1);
          expect(
            controller.taskSnapshotFor(id)!['inbox'].toString(),
            contains('INLINE_DURABLE_EVENT'),
          );
          repository.failEventSave = false;
          final resumed = controller.resumeSessionTask(id);
          await llm.untilRequests(2);
          llm.requests[1].chunks.add(
            const ChatChunk(
              contentDelta: 'recovered inline',
              finishReason: 'stop',
            ),
          );
          await llm.requests[1].chunks.close();
          expect(await resumed, true);
        } else {
          await llm.untilRequests(2);
          expect(
            llm.requests[1].messages.any(
              (m) => m.content.contains('INLINE_DURABLE_EVENT'),
            ),
            true,
          );
          llm.requests[1].chunks.add(
            const ChatChunk(
              contentDelta: 'inline complete',
              finishReason: 'stop',
            ),
          );
          await llm.requests[1].chunks.close();
          await sent;
        }
        var conversation = container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .singleWhere((c) => c.id == id);
        expect(conversation.messages.last.role.name, 'assistant');
        expect(conversation.activePath.last.role.name, 'assistant');
        expect(
          conversation.activePath.any(
            (m) => m.content.contains('INLINE_DURABLE_EVENT'),
          ),
          true,
        );
        expect(controller.taskSnapshotFor(id)!['inbox'], isEmpty);
        container.dispose();
        await createContainer();
        controller = container.read(chatControllerProvider.notifier);
        await controller.selectConversation(id);
        conversation = container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .singleWhere((c) => c.id == id);
        expect(
          conversation.activePath.any(
            (m) => m.content.contains('INLINE_DURABLE_EVENT'),
          ),
          true,
        );
        expect(conversation.messages.last.role.name, 'assistant');
        expect(llm.requests.length, 2);
      },
    );
  }

  for (final restart in [false, true]) {
    test(
      'retains completion after failed preflight; restart=$restart',
      () async {
        var controller = container.read(chatControllerProvider.notifier);
        controller.newConversation(workMode: true, forceNew: true);
        final id = container
            .read(chatControllerProvider)
            .requireValue
            .currentId!;
        final sent = controller.sendMessage('fixture original goal');
        await llm.untilRequests(1);
        final root = container
            .read(workAgentsProvider)
            .records
            .singleWhere((r) => r.external);
        final completed = Completer<WorkProcessResult>();
        container
            .read(workProcessesProvider)
            .start(
              conversationId: id,
              taskId: root.taskId,
              command: 'fixture finite',
              target: 'fixture',
              execute: (_, _) => completed.future,
            );
        llm.requests[0].chunks.add(
          const ChatChunk(
            contentDelta: 'waiting fixture',
            finishReason: 'stop',
          ),
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
        final settings =
            container.read(settingsControllerProvider.notifier)
                as _ControllableSettings;
        settings.fixtureKey('');
        completed.complete(
          const WorkProcessResult(
            exitCode: 0,
            output: 'UNIQUE_COMPLETION_PAYLOAD',
          ),
        );
        for (var i = 0; i < 80; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final failedWake = container.read(chatControllerProvider).requireValue;
        expect(llm.requests.length, 1);
        expect(failedWake.error, contains('API Key'));
        expect(
          failedWake.conversations
              .singleWhere((c) => c.id == id)
              .messages
              .any((m) => m.content.contains('UNIQUE_COMPLETION_PAYLOAD')),
          isFalse,
        );
        expect(
          controller.taskSnapshotFor(id)!['inbox'].toString(),
          contains('UNIQUE_COMPLETION_PAYLOAD'),
        );
        expect(failedWake.sessionCheckpoints[id]!.resumeRequired, isTrue);
        settings.fixtureKey('sk-test');
        if (restart) {
          final originalRoot = controller.taskSnapshotFor(id)!['rootId'];
          container.dispose();
          await createContainer();
          controller = container.read(chatControllerProvider.notifier);
          expect(controller.taskSnapshotFor(id)!['rootId'], originalRoot);
          expect(
            controller.taskSnapshotFor(id)!['inbox'].toString(),
            contains('UNIQUE_COMPLETION_PAYLOAD'),
          );
          expect(llm.requests.length, 1);
          await container
              .read(sessionPolicyProvider.notifier)
              .save(id, const SessionPolicy(approval: WorkApprovalMode.full));
          expect(await controller.resumeSessionTask(id), isFalse);
          expect(llm.requests.length, 1);
          await container
              .read(sessionPolicyProvider.notifier)
              .save(id, const SessionPolicy(remoteRoot: 'changed-target'));
          expect(await controller.resumeSessionTask(id), isFalse);
          expect(llm.requests.length, 1);
          await container
              .read(sessionPolicyProvider.notifier)
              .save(id, const SessionPolicy());
        }
        final recovery = controller.resumeSessionTask(id);
        await llm.untilRequests(2);
        expect(
          llm.requests[1].messages.any(
            (m) => m.content.contains('UNIQUE_COMPLETION_PAYLOAD'),
          ),
          isTrue,
        );
        var finalRequest = 1;
        if (!restart) {
          llm.requests[1].chunks.addError(
            StateError('fixture network failure'),
          );
          await llm.requests[1].chunks.close();
          await recovery;
          expect(
            container
                .read(chatControllerProvider)
                .requireValue
                .sessionCheckpoints[id]!
                .resumeRequired,
            isTrue,
          );
          expect(
            container
                .read(chatControllerProvider)
                .requireValue
                .conversations
                .singleWhere((c) => c.id == id)
                .messages
                .any((m) => m.content.contains('UNIQUE_COMPLETION_PAYLOAD')),
            isTrue,
          );
          final retry = controller.resumeSessionTask(id);
          await llm.untilRequests(3);
          llm.requests[2].chunks.add(
            const ChatChunk(
              contentDelta: 'network recovered',
              finishReason: 'stop',
            ),
          );
          await llm.requests[2].chunks.close();
          expect(await retry, isTrue);
          finalRequest = 2;
        } else {
          llm.requests[1].chunks.add(
            const ChatChunk(
              contentDelta: 'recovered fixture',
              finishReason: 'stop',
            ),
          );
          await llm.requests[1].chunks.close();
          expect(await recovery, isTrue);
        }
        expect(controller.taskSnapshotFor(id)!['inbox'], isEmpty);
        controller.stop(conversationId: id);
        controller.enqueueSessionEvent(
          conversationId: id,
          eventId: 'late-after-stop',
          taskId: root.taskId,
          content: 'must not wake',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(llm.requests.length, finalRequest + 1);
      },
    );
  }
}
