import 'package:expert_chat/features/workbench/agents/work_agents_panel.dart';
import 'package:flutter/material.dart';
import 'package:expert_chat/state/supervisor_settings.dart';
import 'package:expert_chat/state/tool_registry_settings.dart';
import 'package:expert_chat/state/work_approvals.dart';
import 'package:expert_chat/state/role_evolution.dart';
import 'package:expert_chat/state/role_validation_settings.dart';
import 'package:expert_chat/domain/workbench/agents/task_supervisor.dart';
import 'package:expert_chat/domain/workbench/agents/role_trial_validator.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/chat_skill.dart';
import 'package:expert_chat/state/work_memory.dart';
import 'package:expert_chat/platform/credentials.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:expert_chat/domain/remote/device_agent.dart';
import 'package:expert_chat/data/provider_profile.dart';
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
import 'package:expert_chat/features/tui_bridge/backend.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/work_questions.dart';
import 'package:expert_chat/state/work_agents.dart';
import 'package:expert_chat/state/work_processes.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:expert_chat/state/work_rounds.dart';
import 'package:expert_chat/state/work_task_steering.dart';
import 'package:expert_chat/domain/workbench/agents/agent_instructions.dart';
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

class _ControllableSettings extends FakeSettings {
  void useHistoryCap(int count) => state = AsyncData(
    state.requireValue.copyWith(
      context: ContextPrefs(maxHistoryMessages: count),
    ),
  );
  void addDormantMcp() => state = AsyncData(
    state.requireValue.copyWith(
      gateway: state.requireValue.gateway.copyWith(
        mcpTools: const [
          DiscoveredMcpTool(
            name: 'fixture_mutation',
            description: 'Fixture external mutation',
            inputSchema: {'type': 'object', 'properties': {}},
          ),
        ],
      ),
    ),
  );
  List<ProviderProfile> useChannels() {
    final primary = ProviderProfile(
      id: 'primary-fixture',
      name: 'Primary',
      baseUrl: 'https://primary.invalid/v1',
      chatModel: 'deepseek-chat',
      reasonerModel: 'deepseek-chat',
      models: const ['deepseek-chat'],
    );
    final secondary = ProviderProfile(
      id: 'secondary-fixture',
      name: 'Secondary',
      baseUrl: 'https://secondary.invalid/v1',
      chatModel: 'deepseek-chat',
      reasonerModel: 'deepseek-chat',
      models: const ['deepseek-chat'],
    );
    state = AsyncData(
      state.requireValue.copyWith(
        profiles: [primary, secondary],
        activeProfileId: primary.id,
        selectedModel: 'deepseek-chat',
        apiKey: 'primary-old',
      ),
    );
    return [primary, secondary];
  }

  void useVision() => useModels('gpt-4o', const ['gpt-4o']);
  void useModels(String selected, List<String> models) {
    final profile = ProviderProfile(
      name: 'Fixture',
      baseUrl: 'https://fixture.invalid',
      chatModel: selected,
      reasonerModel: selected,
      models: models,
    );
    state = AsyncData(
      state.requireValue.copyWith(
        profiles: [profile],
        activeProfileId: profile.id,
        selectedModel: selected,
      ),
    );
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
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    llm = _BarrierLlm();
    repository = _BarrierRepo();
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
    'pause gates full rounds and user steering retains original goal and root quota',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('original user project goal');
      await llm.untilRequests(1);
      final runtime = container.read(workAgentsProvider);
      final root = runtime.records.singleWhere((r) => r.external);
      root.childrenCreated = 1;
      final assistantId = container
          .read(chatControllerProvider)
          .requireValue
          .current!
          .activePath
          .last
          .id;
      final received = Completer<void>();
      final published = Completer<void>();
      void onRootUpdate() {
        if (root.output == 'partial working content' && !received.isCompleted) {
          received.complete();
        }
      }

      runtime.addListener(onRootUpdate);
      final publication = container.listen(chatControllerProvider, (_, next) {
        final assistant = next.value?.conversations
            .where((c) => c.id == id)
            .firstOrNull
            ?.messages
            .where((m) => m.id == assistantId)
            .firstOrNull;
        if (assistant?.content == 'partial working content' &&
            !published.isCompleted) {
          published.complete();
        }
      });
      try {
        llm.requests[0].chunks.add(
          const ChatChunk(contentDelta: 'partial working content'),
        );
        // Establish received AND presented text before testing that steering
        // preserves it. Request registration precedes stream consumption, and
        // the UI presenter publishes separately; a fixed sleep proves neither.
        await Future.wait([
          received.future,
          published.future,
        ]).timeout(const Duration(seconds: 10));
      } finally {
        runtime.removeListener(onRootUpdate);
        publication.close();
      }
      final originalAssistant = container
          .read(chatControllerProvider)
          .requireValue
          .current!
          .activePath
          .last;
      final receipt = await controller.addWorkRequirement(
        id,
        'Change direction: verify the CSV output',
      );
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .current!
            .messages
            .firstWhere((m) => m.id == originalAssistant.id)
            .content,
        'partial working content',
      );
      container.read(workRoundsProvider.notifier).requestPause(id);
      llm.requests[0].chunks.add(
        const ChatChunk(
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'recall',
              name: 'work_memory_recall',
              argumentsJson: '{}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[0].chunks.close();
      for (
        var i = 0;
        i < 100 && container.read(workRoundsProvider)[id]?.paused != true;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(container.read(workRoundsProvider)[id]!.paused, isTrue);
      expect(llm.requests, hasLength(1));
      container.read(workRoundsProvider.notifier).resume(id);
      await llm.untilRequests(2);
      final pinned = llm.requests[1].messages
          .firstWhere((m) => m.content.startsWith('【固定任务上下文】'))
          .content;
      expect(pinned, contains('original user project goal'));
      expect(pinned, contains('Change direction: verify the CSV output'));
      expect(pinned, isNot(contains('有新的用户运行中补充要求')));
      expect(runtime.records.singleWhere((r) => r.external).id, root.id);
      expect(root.childrenCreated, 1);
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['id'],
        receipt,
      );
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['status'],
        'context_prepared',
      );
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'final result', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, isTrue);
      await expectLater(
        controller.addWorkRequirement(id, 'late requirement'),
        throwsStateError,
      );
    },
  );

  test(
    'steering during a final response continues at the next model boundary',
    () async {
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('Keep the original scope');
      await llm.untilRequests(1);
      final receipt = await controller.addWorkRequirement(
        id,
        'Also explain the CSV format',
      );
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['status'],
        'queued',
      );
      expect(llm.requests.first.token!.isCancelled, false);
      llm.requests.first.chunks.add(
        const ChatChunk(contentDelta: 'First answer', finishReason: 'stop'),
      );
      await llm.requests.first.chunks.close();
      await llm.untilRequests(2).timeout(const Duration(seconds: 10));
      expect(
        llm.requests[1].messages.any(
          (m) => m.content.contains('Also explain the CSV format'),
        ),
        true,
      );
      expect(
        llm.requests[1].messages.any((m) => m.content.contains('有新的用户运行中补充要求')),
        false,
      );
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['id'],
        receipt,
      );
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['round'],
        2,
      );
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'CSV explanation', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, true);
      expect(llm.requests, hasLength(2));
    },
  );

  test(
    'device screenshot becomes model image observation and owned lease is released',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DeviceAgent.channel as MethodChannel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'status') return {'armed': true, 'enabled': true};
        if (call.method == 'observe') return {'revision': 1, 'nodes': []};
        if (call.method == 'screenshot') {
          return Uint8List.fromList(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZuoAAAAASUVORK5CYII=',
            ),
          );
        }
        return {'ok': true};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DeviceAgent.channel as MethodChannel,
          null,
        ),
      );
      (container.read(settingsControllerProvider.notifier)
              as _ControllableSettings)
          .useVision();
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      await container
          .read(sessionPolicyProvider.notifier)
          .save(id, const SessionPolicy(approval: WorkApprovalMode.full));
      final sent = controller.sendMessage('inspect device screenshot');
      await llm.untilRequests(1);
      llm.requests[0].chunks.add(
        const ChatChunk(
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'observe-device',
              name: 'device_observe',
              argumentsJson: '{}',
            ),
            ToolCall(
              index: 1,
              id: 'screen-device',
              name: 'device_action',
              argumentsJson: '{"action":"screenshot","revision":1}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[0].chunks.close();
      await llm.untilRequests(2);
      final observation = llm.requests[1].messages.singleWhere(
        (m) => m.isToolImageObservation,
      );
      expect(observation.toolImageCallId, 'screen-device');
      expect(
        observation.imageDataUrls.single,
        startsWith('data:image/png;base64,'),
      );
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'screen inspected', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, isTrue);
      final lease =
          (calls.firstWhere((c) => c.method == 'observe').arguments
              as Map)['sessionId'];
      final released =
          (calls.lastWhere((c) => c.method == 'releaseOwner').arguments
              as Map)['sessionId'];
      expect(released, lease);
    },
  );

  for (final rootVision in [false, true]) {
    test('child screenshot capability follows child, rootVision=$rootVision', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final nativeCalls = <String>[];
      messenger.setMockMethodCallHandler(DeviceAgent.channel as MethodChannel, (
        call,
      ) async {
        nativeCalls.add(call.method);
        if (call.method == 'status') return {'armed': true, 'enabled': true};
        if (call.method == 'observe') return {'revision': 1, 'nodes': []};
        if (call.method == 'screenshot') {
          return Uint8List.fromList(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZuoAAAAASUVORK5CYII=',
            ),
          );
        }
        return {'ok': true};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DeviceAgent.channel as MethodChannel,
          null,
        ),
      );
      final rootModel = rootVision ? 'gpt-4o' : 'deepseek-chat';
      final childModel = rootVision ? 'deepseek-chat' : 'gpt-4o';
      (container.read(settingsControllerProvider.notifier)
              as _ControllableSettings)
          .useModels(rootModel, const ['gpt-4o', 'deepseek-chat']);
      final profile = container
          .read(settingsControllerProvider)
          .requireValue
          .active!;
      await container
          .read(secureStorageProvider)
          .write(
            key: providerApiKeyStorageKey(profile.id),
            value: 'fixture-key',
          );
      await container.read(workAgentModelPoolProvider.notifier).save(const [
        WorkAgentModelOption('gpt-4o'),
        WorkAgentModelOption('deepseek-chat'),
      ]);
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      await container
          .read(sessionPolicyProvider.notifier)
          .save(id, const SessionPolicy(approval: WorkApprovalMode.full));
      final sent = controller.sendMessage('root device task');
      await llm.untilRequests(1);
      final runtime = container.read(workAgentsProvider);
      final root = runtime.records.singleWhere((r) => r.external);
      final inherited = root.environment;
      // Keep the real host executor/preparation; remove only the role-selection
      // model request so this fixture isolates per-child vision ownership.
      root.environment = WorkAgentEnvironment(
        provider: inherited.provider,
        config: inherited.config,
        tools: inherited.tools,
        executeTool: inherited.executeTool,
        resolveModel: inherited.resolveModel,
        modelPool: inherited.modelPool,
        prepareMessages: inherited.prepareMessages,
        prepareTools: inherited.prepareTools,
        beforeRound: inherited.beforeRound,
        takeToolObservations: inherited.takeToolObservations,
        onRuntimeLog: inherited.onRuntimeLog,
      );
      final child = runtime.spawn(
        parentId: root.id,
        task: 'child screenshot task',
        model: childModel,
        readOnly: true,
      );
      await llm
          .untilRequests(2)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw StateError(
              'child status ${runtime.record(child)!.status}: ${runtime.record(child)!.output}',
            ),
          );
      expect(llm.requests[1].config.model, childModel);
      llm.requests[1].chunks.add(
        const ChatChunk(
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'observe-child',
              name: 'device_observe',
              argumentsJson: '{}',
            ),
            ToolCall(
              index: 1,
              id: 'screen-child',
              name: 'device_action',
              argumentsJson: '{"action":"screenshot","revision":1}',
            ),
            ToolCall(
              index: 2,
              id: 'forbidden-click',
              name: 'device_action',
              argumentsJson: '{"action":"tap","revision":1,"target":"button"}',
            ),
            ToolCall(
              index: 3,
              id: 'forbidden-document',
              name: 'edit_document',
              argumentsJson: '{}',
            ),
            ToolCall(
              index: 4,
              id: 'forbidden-external',
              name: 'external_mutation',
              argumentsJson: '{}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[1].chunks.close();
      await llm.untilRequests(3);
      final images = llm.requests[2].messages
          .where((m) => m.isToolImageObservation)
          .toList();
      expect(images.length, rootVision ? 0 : 1);
      expect(nativeCalls, isNot(contains('tap')));
      for (final denied in [
        'forbidden-click',
        'forbidden-document',
        'forbidden-external',
      ]) {
        expect(
          llm.requests[2].messages
              .singleWhere((m) => m.toolCallId == denied)
              .content,
          contains('只读职责'),
        );
      }
      if (images.isNotEmpty) {
        expect(
          llm.requests[2].messages.indexOf(images.single),
          greaterThan(
            llm.requests[2].messages.lastIndexWhere(
              (m) => m.role == MessageRole.tool,
            ),
          ),
        );
      }
      if (images.isNotEmpty) {
        expect(images.single.toolImageCallId, 'screen-child');
      }
      llm.requests[2].chunks.add(
        const ChatChunk(contentDelta: 'child inspected', finishReason: 'stop'),
      );
      await llm.requests[2].chunks.close();
      for (var i = 0; i < 100 && !runtime.record(child)!.terminal; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(runtime.record(child)!.status, WorkAgentStatus.completed);
      await controller.stopAndWait(conversationId: id);
      await sent;
    });
  }

  test(
    'automatic public checkpoint fires at effective history cap before main request',
    () async {
      (container.read(settingsControllerProvider.notifier)
              as _ControllableSettings)
          .useHistoryCap(4);
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('fixed original user goal');
      await llm.untilRequests(1);
      expect(llm.requests[0].messages.first.content, contains('只输出 JSON'));
      expect(
        llm.requests[0].messages.any(
          (m) => m.reasoningContent?.isNotEmpty == true,
        ),
        isFalse,
      );
      llm.requests[0].chunks.add(
        const ChatChunk(
          contentDelta:
              '{"summary":"verified public state","constraints":"preserve user edits","plan":"next verification","open_questions":[]}',
          finishReason: 'stop',
        ),
      );
      await llm.requests[0].chunks.close();
      await llm.untilRequests(2);
      final pinned = llm.requests[1].messages
          .firstWhere((m) => m.content.startsWith('【固定任务上下文】'))
          .content;
      expect(pinned, contains('fixed original user goal'));
      expect(pinned, contains('verified public state'));
      expect(
        container.read(workMemoryProvider).snapshot(id)['compact_revision'],
        1,
      );
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'finished', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, isTrue);
    },
  );

  for (final duringApproval in [false, true]) {
    test(
      'supervisor discards user-steered stale advice and activation, duringApproval=$duringApproval',
      () async {
        final settings = container
            .read(settingsControllerProvider)
            .requireValue;
        await container
            .read(secureStorageProvider)
            .write(
              key: providerApiKeyStorageKey(settings.active!.id),
              value: 'fixture-credential',
            );
        if (duringApproval) {
          (container.read(settingsControllerProvider.notifier)
                  as _ControllableSettings)
              .addDormantMcp();
        } else {
          await container
              .read(toolRegistrySettingsProvider.notifier)
              .configure(mathEnabled: true);
        }
        await container
            .read(supervisorSettingsProvider.notifier)
            .save(
              SupervisorConfig(
                enabled: true,
                model: settings.model,
                minRoundGap: 1,
              ),
            );
        final controller = container.read(chatControllerProvider.notifier);
        controller.newConversation(workMode: true, forceNew: true);
        final id = container
            .read(chatControllerProvider)
            .requireValue
            .currentId!;
        if (duringApproval) {
          controller.setCustomMcpServerIds(['expert-chat']);
        }
        final sent = controller.sendMessage(
          'immutable original supervisor goal',
        );
        await llm.untilRequests(1);
        llm.requests[0].chunks.add(
          const ChatChunk(
            toolCalls: [
              ToolCall(
                index: 0,
                id: 'bad-memory',
                name: 'work_memory_checkpoint',
                argumentsJson: '{"expected_revision":999,"summary":"invalid"}',
              ),
            ],
            finishReason: 'tool_calls',
          ),
        );
        await llm.requests[0].chunks.close();
        await llm.untilRequests(2).timeout(const Duration(seconds: 3));
        final target = duringApproval ? 'fixture_mutation' : 'math_calculate';
        final source = jsonDecode(llm.requests[1].messages.last.content) as Map;
        expect(source['goal'], 'immutable original supervisor goal');
        expect(source['available_tools'], contains(target));
        if (!duringApproval) {
          await controller.addWorkRequirement(
            id,
            'New direction: only report, do not edit',
          );
        }
        llm.requests[1].chunks.add(
          ChatChunk(
            contentDelta: jsonEncode({
              'advice': 'STALE_ADVICE_MUST_NOT_APPEAR',
              'requested_tools': [target],
              'suggested_model': '',
              'evidence': 'fixture capability gap',
            }),
            finishReason: 'stop',
          ),
        );
        await llm.requests[1].chunks.close();
        if (duringApproval) {
          for (
            var i = 0;
            i < 150 && container.read(workApprovalsProvider).isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
          final approval = container.read(workApprovalsProvider).single;
          expect(approval.tool, target);
          await controller.addWorkRequirement(
            id,
            'Changed while approval waits: no external changes',
          );
          container
              .read(workApprovalsProvider.notifier)
              .decide(approval.id, true);
        }
        await llm.untilRequests(3).timeout(const Duration(seconds: 3));
        expect(
          llm.requests[2].messages.any(
            (m) => m.content.contains('STALE_ADVICE_MUST_NOT_APPEAR'),
          ),
          isFalse,
        );
        expect(llm.requests[2].tools.any((t) => t.name == target), isFalse);
        expect(
          llm.requests[2].messages.any(
            (m) => m.content.contains(
              duringApproval
                  ? 'Changed while approval waits'
                  : 'New direction: only report',
            ),
          ),
          isTrue,
        );
        llm.requests[2].chunks.add(
          const ChatChunk(
            contentDelta: 'updated final report',
            finishReason: 'stop',
          ),
        );
        await llm.requests[2].chunks.close();
        expect(await sent, isTrue);
      },
    );
  }

  for (final stopMode in [0, 1, 2, 3]) {
    final stopViaRuntime = stopMode.isOdd;
    final beforeReview = stopMode >= 2;
    test(
      'completed-child auxiliary review cancels with root without resurrecting completion, runtimeStop=$stopViaRuntime beforeReview=$beforeReview',
      () async {
        final settings = container
            .read(settingsControllerProvider)
            .requireValue;
        await container
            .read(secureStorageProvider)
            .write(
              key: providerApiKeyStorageKey(settings.active!.id),
              value: 'fixture-key',
            );
        await container
            .read(roleValidationSettingsProvider.notifier)
            .save(const RoleValidationConfig(enabled: true, autoPromote: true));
        final roles = container.read(roleEvolutionProvider.notifier);
        final search = roles.search(
          task: '摘要与缺口',
          roles: settings.effectiveSubagentRoles,
          availableTools: [],
        );
        final candidate = await roles.propose(
          searchId: search['search_id'] as String,
          name: '公开摘要角色',
          when: '摘要与缺口',
          instructions: '根据公开文字给出三条摘要并指出尚缺资料。',
          model: settings.model,
          requiredTools: [],
          source: 'fixture provided notes',
        );
        final controller = container.read(chatControllerProvider.notifier);
        controller.newConversation(workMode: true, forceNew: true);
        final id = container
            .read(chatControllerProvider)
            .requireValue
            .currentId!;
        final sent = controller.sendMessage('整理给定公开说明');
        await llm.untilRequests(1);
        final runtime = container.read(workAgentsProvider);
        final root = runtime.records.singleWhere((r) => r.external);
        final inherited = root.environment;
        final callback = inherited.onRoleTrialCompleted!;
        final childId = runtime.spawn(
          parentId: root.id,
          task: '把给定公开说明写成三点摘要，并明确尚未给出的资料。',
          model: settings.model,
          candidateId: candidate.role.id,
          readOnly: true,
        );
        final child = runtime.record(childId)!;
        // Delay the actual host completion continuation to the documented disk-
        // flush race after the main task finished; retain the real child engine.
        child.environment = WorkAgentEnvironment(
          provider: inherited.provider,
          config: inherited.config,
          tools: inherited.tools,
          executeTool: inherited.executeTool,
          resolveModel: inherited.resolveModel,
          modelPool: inherited.modelPool,
          roles: inherited.roles,
          selectRole: inherited.selectRole,
          prepareMessages: inherited.prepareMessages,
          prepareTools: inherited.prepareTools,
          beforeRound: inherited.beforeRound,
          takeToolObservations: inherited.takeToolObservations,
          onRuntimeLog: inherited.onRuntimeLog,
        );
        await llm
            .untilRequests(2)
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () => fail(
                'Child request missing: ${child.status} / ${child.activity} / ${child.output}',
              ),
            );
        llm.requests[1].chunks.add(
          const ChatChunk(
            contentDelta: '第一点说明；第二点限制；第三点现状。缺口：尚未提供原始资料。',
            finishReason: 'stop',
          ),
        );
        await llm.requests[1].chunks.close();
        for (var i = 0; i < 150 && !child.terminal; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(child.status, WorkAgentStatus.completed);
        llm.requests[0].chunks.add(
          const ChatChunk(contentDelta: 'initial report', finishReason: 'stop'),
        );
        await llm.requests[0].chunks.close();
        await llm
            .untilRequests(3)
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () => fail(
                'Continuation missing: ${root.status} / ${child.status}',
              ),
            );
        llm.requests[2].chunks.add(
          const ChatChunk(
            contentDelta: 'consolidated completed report',
            finishReason: 'stop',
          ),
        );
        await llm.requests[2].chunks.close();
        expect(await sent, true);
        for (var i = 0; i < 150 && controller.isConversationRunning(id); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(root.status, WorkAgentStatus.completed);
        final gatedRoles = roles as _GatedRoleEvolution;
        if (beforeReview) {
          gatedRoles.evidenceGate = Completer<void>();
          gatedRoles.evidenceEntered = Completer<void>();
        }
        callback(child, child.roleTrial!);
        if (beforeReview) {
          await gatedRoles.evidenceEntered!.future;
          expect(root.auxiliaryActivity, isEmpty);
          if (stopViaRuntime) {
            runtime.cancel(root.id);
          } else {
            await controller.stopAndWait(conversationId: id);
          }
          gatedRoles.evidenceGate!.complete();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            llm.requests,
            hasLength(3),
            reason: 'No review may start after stop during evidence flush',
          );
          expect(root.status, WorkAgentStatus.completed);
          expect(controller.isConversationRunning(id), isFalse);
          expect(
            container
                .read(settingsControllerProvider)
                .requireValue
                .effectiveSubagentRoles
                .any((r) => r.id == candidate.role.id),
            isFalse,
          );
          return;
        }
        await llm.untilRequests(4).timeout(const Duration(seconds: 3));
        expect(llm.requests[3].messages.first.content, contains('待复用角色'));
        expect(root.status, WorkAgentStatus.completed);
        expect(root.auxiliaryActivity, isNotEmpty);
        if (stopViaRuntime) {
          runtime.cancel(root.id);
        } else {
          await controller.stopAndWait(conversationId: id);
        }
        await Future<void>.delayed(Duration.zero);
        expect(llm.requests[3].token!.isCancelled, isTrue);
        expect(
          child.token.isCancelled,
          isFalse,
          reason:
              'Completed child token must not be the cancellation authority',
        );
        llm.requests[3].chunks.add(
          const ChatChunk(
            contentDelta:
                '{"pass":true,"criteria":"公开摘要覆盖三点且明确指出缺少原始资料。","limitations":"fixture only"}',
            finishReason: 'stop',
          ),
        );
        await llm.requests[3].chunks.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          container
              .read(roleEvolutionProvider)
              .single
              .evidence
              .any((e) => e['reviewPassed'] == true),
          isFalse,
        );
        expect(
          container
              .read(settingsControllerProvider)
              .requireValue
              .effectiveSubagentRoles
              .any((r) => r.id == candidate.role.id),
          isFalse,
        );
        expect(root.status, WorkAgentStatus.completed);
        expect(controller.isConversationRunning(id), isFalse);
        expect(llm.requests, hasLength(4));
      },
    );
  }

  test(
    'accepted secondary credential rotation stays on its channel and preserves DeepSeek continuation',
    () async {
      final profiles =
          (container.read(settingsControllerProvider.notifier)
                  as _ControllableSettings)
              .useChannels();
      for (final profile in profiles) {
        await container
            .read(secureStorageProvider)
            .write(
              key: providerApiKeyStorageKey(profile.id),
              value: profile.id == profiles.first.id
                  ? 'primary-old'
                  : 'secondary-old',
            );
      }
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      final sent = controller.sendMessage('continue accepted channel');
      await llm.untilRequests(1);
      final accepted = llm.requests[0].config.copyWith(
        profileId: profiles.last.id,
        baseUrl: profiles.last.baseUrl,
        apiKey: 'secondary-old',
      );
      llm.requests[0].chunks.add(
        ChatChunk(
          actualConfig: accepted,
          reasoningDelta: 'required provider continuation',
          responseOutputItems: const [
            {'type': 'reasoning', 'encrypted_content': 'old-account'},
          ],
          toolCalls: const [
            ToolCall(
              index: 0,
              id: 'hold-key',
              name: 'work_ask_user',
              argumentsJson:
                  '{"questions":[{"id":"q","question":"continue?","options":["yes"]}]}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[0].chunks.close();
      for (
        var i = 0;
        i < 150 && container.read(workQuestionsProvider).isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final question = container.read(workQuestionsProvider).single;
      await container
          .read(settingsControllerProvider.notifier)
          .setProfileApiKey(profiles.last.id, 'secondary-new');
      container.read(workQuestionsProvider.notifier).answer(question.id, {
        'q': {
          'selected': ['yes'],
          'text': '',
        },
      });
      await llm.untilRequests(2).timeout(const Duration(seconds: 3));
      expect(llm.requests[1].config.profileId, profiles.last.id);
      expect(llm.requests[1].config.baseUrl, profiles.last.baseUrl);
      expect(llm.requests[1].config.apiKey, 'secondary-new');
      expect(
        llm.requests[1].config.routingSessionId,
        accepted.routingSessionId,
      );
      final continuation = llm.requests[1].messages.firstWhere(
        (m) => m.toolCalls.any((c) => c.id == 'hold-key'),
      );
      expect(continuation.reasoningContent, 'required provider continuation');
      expect(continuation.responseOutputItems, isEmpty);
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'continued', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, isTrue);
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .sessionCheckpoints[id]!
            .status,
        SessionExecutionStatus.completed,
      );
    },
  );

  test(
    'explicit vision to text model switch at full boundary removes pixels but keeps UI originals',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DeviceAgent.channel as MethodChannel, (
        call,
      ) async {
        if (call.method == 'status') return {'armed': true, 'enabled': true};
        if (call.method == 'observe') return {'revision': 1};
        if (call.method == 'screenshot') {
          return Uint8List.fromList(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZuoAAAAASUVORK5CYII=',
            ),
          );
        }
        return {'ok': true};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          DeviceAgent.channel as MethodChannel,
          null,
        ),
      );
      (container.read(settingsControllerProvider.notifier)
              as _ControllableSettings)
          .useVision();
      final controller = container.read(chatControllerProvider.notifier);
      controller.newConversation(workMode: true, forceNew: true);
      final id = container.read(chatControllerProvider).requireValue.currentId!;
      await container
          .read(sessionPolicyProvider.notifier)
          .save(id, const SessionPolicy(approval: WorkApprovalMode.full));
      final sent = controller.sendMessage('observe then switch model');
      await llm.untilRequests(1);
      llm.requests[0].chunks.add(
        const ChatChunk(
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'observe-switch',
              name: 'device_observe',
              argumentsJson: '{}',
            ),
            ToolCall(
              index: 1,
              id: 'image-switch',
              name: 'device_action',
              argumentsJson: '{"action":"screenshot","revision":1}',
            ),
            ToolCall(
              index: 2,
              id: 'hold-switch',
              name: 'work_ask_user',
              argumentsJson:
                  '{"questions":[{"id":"q","question":"switch?","options":["yes"]}]}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[0].chunks.close();
      for (
        var i = 0;
        i < 150 && container.read(workQuestionsProvider).isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final question = container.read(workQuestionsProvider).single;
      (container.read(settingsControllerProvider.notifier)
              as _ControllableSettings)
          .useModels('deepseek-chat', const ['gpt-4o', 'deepseek-chat']);
      container.read(workQuestionsProvider.notifier).answer(question.id, {
        'q': {
          'selected': ['yes'],
          'text': '',
        },
      });
      await llm.untilRequests(2).timeout(const Duration(seconds: 3));
      expect(llm.requests[1].config.model, 'deepseek-chat');
      expect(llm.requests[1].messages.any((m) => m.hasImageParts), isFalse);
      expect(
        llm.requests[1].messages.any((m) => m.content.contains('像素未发送')),
        isTrue,
      );
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .current!
            .messages
            .any((m) => m.attachments.any((a) => a.hasImageData)),
        isTrue,
      );
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'text fallback', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
      expect(await sent, isTrue);
    },
  );

  testWidgets(
    'root agent panel routes active input as user steering and keeps rejected completed draft',
    (tester) async {
      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = container.read(chatControllerProvider.notifier);
      late String id;
      late Future<bool> sent;
      await tester.runAsync(() async {
        controller.newConversation(workMode: true, forceNew: true);
        id = container.read(chatControllerProvider).requireValue.currentId!;
        sent = controller.sendMessage('panel original user goal');
        await llm
            .untilRequests(1)
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () => throw StateError(
                'panel initial model request absent: ${container.read(chatControllerProvider).value?.error}',
              ),
            );
      });
      final runtime = container.read(workAgentsProvider);
      final root = runtime.records.singleWhere((r) => r.external);
      root.childrenCreated = 1;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: WorkAgentsPanel(conversationId: id)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '发送补充信息或后续任务',
      );
      await tester.enterText(field, 'PANEL_USER_DIRECTION_ONLY_REPORT');
      await tester.runAsync(() => tester.tap(find.byTooltip('发送后续任务')));
      // The tap begins in the widget clock, while durable receipt and history
      // writes resume on the real asynchronous clock. Drive both until accepted.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        if ((tester.widget<TextField>(field)).controller!.text.isEmpty) break;
      }
      expect((tester.widget<TextField>(field)).controller!.text, isEmpty);
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['text'],
        'PANEL_USER_DIRECTION_ONLY_REPORT',
      );
      await tester.runAsync(() async {
        llm.requests[0].chunks.add(
          const ChatChunk(contentDelta: 'first reply', finishReason: 'stop'),
        );
        await llm.requests[0].chunks.close();
        await llm.untilRequests(2).timeout(const Duration(seconds: 3));
        final pinned = llm.requests[1].messages
            .firstWhere((m) => m.content.startsWith('【固定任务上下文】'))
            .content;
        expect(pinned, contains('panel original user goal'));
        expect(pinned, contains('PANEL_USER_DIRECTION_ONLY_REPORT'));
        llm.requests[1].chunks.add(
          const ChatChunk(
            contentDelta: 'finished with updated direction',
            finishReason: 'stop',
          ),
        );
        await llm.requests[1].chunks.close();
        expect(await sent, true);
        for (var i = 0; i < 150 && controller.isConversationRunning(id); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      });
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, 'keep completed task draft');
      await tester.runAsync(() => tester.tap(find.byTooltip('发送后续任务')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(
        (tester.widget<TextField>(field)).controller!.text,
        'keep completed task draft',
      );
      expect(find.textContaining('任务已结束'), findsWidgets);
      expect(root.childrenCreated, 1);
      expect(llm.requests, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
      // This boundary test deliberately starts off, then enables thinking while
      // both tools are in flight; fresh conversations now default to on.
      if (container.read(chatControllerProvider).requireValue.deepThink) {
        controller.toggleDeepThink();
      }
      final sent = controller.sendMessage('ask two necessary questions');
      await llm.untilRequests(1);
      expect(llm.requests.first.thinking, isFalse);
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
      controller.renameConversation(id, 'steering boundary fixture');
      final bridge = ControllerBridgeBackend(container);
      final reply = await bridge.invoke('queue.add', {
        'session_id': id,
        'text': 'After both tools, inspect the CSV only.',
      });
      final receiptId = reply['id'];
      expect((reply['steering'] as Map)['status'], 'queued');
      final waitingSnapshot = await bridge.snapshot(id);
      expect((waitingSnapshot['queued'] as List).single['id'], receiptId);
      final waitingMessage = (waitingSnapshot['messages'] as List).firstWhere(
        (m) => m['id'] == receiptId,
      );
      expect(waitingMessage['steering']['status'], 'queued');
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
      expect(
        container.read(workTaskSteeringProvider).snapshot(id).single['status'],
        'queued',
      );
      container.read(workQuestionsProvider.notifier).answer(second.id, {
        'q1': {'text': 'answer 1'},
      });
      await llm.untilRequests(2);
      expect(llm.requests[1].thinking, isTrue);
      expect(
        llm.requests[1].messages.any(
          (m) => m.content.contains('After both tools, inspect the CSV only.'),
        ),
        isTrue,
      );
      final preparedSnapshot = await bridge.snapshot(id);
      expect(preparedSnapshot['queued'], isEmpty);
      final preparedMessage = (preparedSnapshot['messages'] as List).firstWhere(
        (m) => m['id'] == receiptId,
      );
      expect(preparedMessage['steering']['status'], 'context_prepared');
      expect(preparedMessage['steering']['round'], 2);
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
      expect(
        await controller.sendMessage('duplicate send while running'),
        isFalse,
      );
      llm.requests[0].chunks.add(
        ChatChunk(
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'prior-failed-call',
              name: 'work_memory_checkpoint',
              argumentsJson:
                  '{"expected_revision":999,"summary":"not committed"}',
            ),
            ToolCall(
              index: 1,
              id: 'prior-result-call',
              name: 'work_memory_checkpoint',
              argumentsJson: jsonEncode({
                'expected_revision': 0,
                'summary':
                    'first completed input ${List.filled(3000, 'x').join()}',
              }),
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[0].chunks.close();
      await llm.untilRequests(2);
      llm.requests[1].chunks.add(
        const ChatChunk(contentDelta: 'initial reply', finishReason: 'stop'),
      );
      await llm.requests[1].chunks.close();
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
      await llm.untilRequests(3);
      expect(runtime.records.where((r) => r.external).length, 1);
      expect(runtime.records.singleWhere((r) => r.external).id, root.id);
      expect(root.childrenCreated, 3);
      final pinned = llm.requests[2].messages
          .firstWhere((m) => m.content.startsWith('【固定任务上下文】'))
          .content;
      expect(pinned, contains('audit current workspace'));
      expect(pinned, isNot(contains('后台任务事件')));
      expect(pinned, isNot(contains('audit complete')));
      expect(
        llm.requests[2].messages.any(
          (m) =>
              m.content.contains('【此前工具执行记录】') &&
              m.content.contains('work_memory_checkpoint') &&
              m.content.contains('first completed input'),
        ),
        isTrue,
      );
      expect(
        container
            .read(chatControllerProvider)
            .requireValue
            .conversations
            .firstWhere((c) => c.id == id)
            .messages
            .where((m) => m.role == MessageRole.user),
        hasLength(1),
      );
      final evidence = llm.requests[2].messages
          .firstWhere((m) => m.content.startsWith('【此前工具执行记录】'))
          .content;
      expect(evidence, contains('"status":"failed"'));
      expect(evidence, contains('"status":"done"'));
      expect(evidence, contains('历史成功不证明当前文件/输入未变'));
      expect(evidence, contains('有截断/省略'));
      expect(evidence.length, lessThan(13000));
      expect(container.read(workMemoryProvider).snapshot(id)['revision'], 1);
      // Changed input may legitimately execute the same tool again.
      llm.requests[2].chunks.add(
        const ChatChunk(
          toolCalls: [
            ToolCall(
              index: 0,
              id: 'changed-input-call',
              name: 'work_memory_checkpoint',
              argumentsJson:
                  '{"expected_revision":1,"summary":"changed input verified"}',
            ),
          ],
          finishReason: 'tool_calls',
        ),
      );
      await llm.requests[2].chunks.close();
      await llm.untilRequests(4);
      expect(container.read(workMemoryProvider).snapshot(id)['revision'], 2);
      llm.requests[3].chunks.add(
        const ChatChunk(contentDelta: 'combined report', finishReason: 'stop'),
      );
      await llm.requests[3].chunks.close();
      for (var i = 0; i < 100 && controller.isConversationRunning(id); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(controller.isConversationRunning(id), isFalse);
      expect(root.rounds, 4);
      expect(root.output, 'combined report');
      final next = controller.sendMessage('a separate user task');
      await llm.untilRequests(5);
      expect(
        llm.requests[4].messages.any((m) => m.content.contains('【此前工具执行记录】')),
        isFalse,
      );
      expect(runtime.records.where((r) => r.external), hasLength(2));
      llm.requests[4].chunks.add(
        const ChatChunk(contentDelta: 'new task done', finishReason: 'stop'),
      );
      await llm.requests[4].chunks.close();
      expect(await next, isTrue);
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
      await settings.setChatSkills(
        ChatSkillCatalog.factory(generalPrompt: 'CORE: speak naturally'),
      );
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
      expect(
        child.any((m) => m.content.contains('CORE: speak naturally')),
        isTrue,
      );
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
