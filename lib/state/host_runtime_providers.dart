import 'dart:async';
import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../domain/host/host_client.dart';
import '../domain/host/wire_models.dart';
import 'work_approvals.dart';
import 'work_questions.dart';
import 'work_rounds.dart';
import 'session_policy.dart';
import 'conversation_model_choice.dart';
import 'conversation_workspace_bindings.dart';
import 'work_agents.dart';
import 'work_changes.dart';
import 'work_task_runtime.dart';
import 'work_runtime_logs.dart';
import 'task_acceptance_provider.dart';
import 'task_plans.dart';
import 'work_memory.dart';
import 'role_evolution.dart';
import '../data/subagent_role.dart';
import 'work_session_insights.dart';
import 'work_task_steering.dart';
import '../core/providers.dart';
import '../domain/llm/model_usage_store.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/host/llm_wire.dart';

Map<String, dynamic> hostRuntime() =>
    wireMap(HostClient.current!.state['runtime']);

class HostTaskPlans extends TaskPlans {
  @override
  Map<String, TaskPlan> build() => projectHostState(
    ref,
    'plans',
    (raw) => wireMap(
      raw,
    ).map((key, value) => MapEntry(key, TaskPlan.fromJson(wireMap(value)))),
    (value) => state = value,
  );
}

Future<Object?> hostRuntimeCall(String operation, Map<String, Object?> args) =>
    HostClient.current!.call('runtime', operation, args);
void hostRuntimeFire(String operation, Map<String, Object?> args) => unawaited(
  hostRuntimeCall(operation, args).catchError((Object error) {
    HostClient.current?.reportError(error.toString());
    return null;
  }),
);

T projectHostState<T>(
  Ref ref,
  String key,
  T Function(Object?) decode,
  void Function(T) update,
) {
  Object? previousRaw = hostRuntime()[key];
  var signature = jsonEncode(previousRaw);
  final subscription = HostClient.current!.updates.listen((value) {
    if (!ref.mounted || value['runtime'] == null) return;
    final raw = wireMap(value['runtime'])[key];
    if (identical(previousRaw, raw)) return;
    previousRaw = raw;
    final next = jsonEncode(raw);
    if (next != signature) {
      signature = next;
      update(decode(raw));
    }
  });
  ref.onDispose(subscription.cancel);
  return decode(hostRuntime()[key]);
}

class HostWorkApprovals extends WorkApprovals {
  @override
  List<PendingWorkApproval> build() => projectHostState(
    ref,
    'approvals',
    (raw) => wireRows(raw)
        .map(
          (a) => PendingWorkApproval(
            id: a['id'] as String,
            conversationId: a['conversationId'] as String,
            sourceAgentId: a['sourceAgentId'] as String?,
            toolCallId: a['toolCallId'] as String?,
            tool: a['tool'] as String,
            arguments: a['arguments'] as String,
            target: a['target'] as String,
            reason: a['reason'] as String,
          ),
        )
        .toList(),
    (value) => state = value,
  );
  @override
  void decideScoped(
    String conversation,
    String id,
    String decision, {
    String? reason,
  }) => hostRuntimeFire('approval.decide', {
    'conversation': conversation,
    'id': id,
    'decision': decision,
    'reason': reason,
  });
  @override
  void decide(String id, bool approved) {
    final request = state.where((r) => r.id == id).firstOrNull;
    if (request != null) {
      decideScoped(request.conversationId, id, approved ? 'once' : 'reject');
    }
  }

  @override
  void revokeSession(String conversation) =>
      hostRuntimeFire('approval.revoke', {'conversation': conversation});
}

class HostWorkQuestions extends WorkQuestions {
  @override
  List<PendingWorkQuestion> build() => projectHostState(
    ref,
    'questions',
    (raw) => wireRows(raw)
        .map(
          (q) => PendingWorkQuestion(
            id: q['id'] as String,
            conversationId: q['conversationId'] as String,
            sourceAgentId: q['sourceAgentId'] as String?,
            assistantId: q['assistantId'] as String,
            questions: WorkQuestion.parse({'questions': q['questions']}),
          ),
        )
        .toList(),
    (value) => state = value,
  );
  @override
  void answer(String id, Map<String, dynamic> answers) =>
      hostRuntimeFire('question.answer', {'id': id, 'answers': answers});
}

class HostWorkRounds extends WorkRounds {
  @override
  Map<String, WorkRoundProgress> build() => projectHostState(
    ref,
    'rounds',
    (raw) => wireMap(raw).map((key, value) {
      final r = wireMap(value);
      return MapEntry(
        key,
        WorkRoundProgress(
          runId: r['runId'] as String,
          limit: r['limit'] as int,
          step: r['step'] as int,
          reviewAhead: r['reviewAhead'] as int,
          autoExtend: r['autoExtend'] as bool,
          used: r['used'] as int,
          reviewedLimit: r['reviewedLimit'] as int,
          reviewing: r['reviewing'] as bool,
          finishing: r['finishing'] as bool,
          active: r['active'] as bool,
          revision: r['revision'] as int,
          note: r['note'] as String,
          pauseRequested: r['pauseRequested'] as bool,
          paused: r['paused'] as bool,
        ),
      );
    }),
    (value) => state = value,
  );
  @override
  void requestPause(String conversation) =>
      hostRuntimeFire('rounds.pause', {'conversation': conversation});
  @override
  void resume(String conversation) =>
      hostRuntimeFire('rounds.resume', {'conversation': conversation});
  @override
  void addRounds(String conversation) =>
      hostRuntimeFire('rounds.add', {'conversation': conversation});
}

class HostSessionPolicies extends SessionPolicies {
  @override
  Map<String, SessionPolicy> build() => projectHostState(
    ref,
    'policies',
    (raw) => wireMap(
      raw,
    ).map((k, v) => MapEntry(k, SessionPolicy.fromJson(wireMap(v)))),
    (value) => state = value,
  );
  @override
  Future<void> save(String id, SessionPolicy policy) => saveMany({id: policy});
  @override
  Future<void> saveMany(Map<String, SessionPolicy> updates) async {
    await hostRuntimeCall('policy.saveMany', {
      'updates': updates.map((k, v) => MapEntry(k, v.toJson())),
    });
  }
}

class HostConversationModelChoice extends ConversationModelChoice {
  @override
  Map<String, String> build() => projectHostState(
    ref,
    'modelChoices',
    (raw) => Map<String, String>.from(raw as Map? ?? {}),
    (value) => state = value,
  );
  @override
  Future<void> select(String conversation, String model) async {
    await hostRuntimeCall('model.select', {
      'conversation': conversation,
      'model': model,
    });
  }
}

class HostWorkspaceBindings extends ConversationWorkspaceBindings {
  @override
  Map<String, String> build() => projectHostState(
    ref,
    'workspaceBindings',
    (raw) => Map<String, String>.from(raw as Map? ?? {}),
    (value) => state = value,
  );
  @override
  Future<void> select(String conversationId, String? workspaceId) async {
    await hostRuntimeCall('workspace.select', {
      'conversation': conversationId,
      'workspace': workspaceId,
    });
  }
}

class HostAgentModelPool extends WorkAgentModelPool {
  @override
  List<WorkAgentModelOption>? build() => projectHostState(
    ref,
    'agentModels',
    (raw) => raw == null
        ? null
        : wireRows(raw).map(WorkAgentModelOption.fromJson).toList(),
    (value) => state = value,
  );
  @override
  Future<void> save(List<WorkAgentModelOption> models) async {
    await hostRuntimeCall('agents.models', {
      'models': models.map((m) => m.toJson()).toList(),
    });
  }
}

class HostWorkChanges extends WorkChanges {
  @override
  List<WorkFileChange> build() {
    ready = Future.value();
    return projectHostState(
      ref,
      'changes',
      (raw) => wireRows(raw).map(WorkFileChange.fromJson).toList(),
      (value) => state = value,
    );
  }
}

class HostTaskRuntime extends WorkTaskRuntime {
  @override
  List<WorkTaskRecord> build() => projectHostState(
    ref,
    'tasks',
    (raw) => wireRows(raw)
        .map(
          (r) => WorkTaskRecord(
            id: r['id'] as String,
            conversationId: r['conversationId'] as String,
            title: r['title'] as String,
            startedAt: DateTime.parse(r['startedAt'] as String),
            finishedAt: DateTime.tryParse(r['finishedAt'] as String? ?? ''),
            status: WorkTaskStatus.values.byName(r['status'] as String),
            detail: r['detail'] as String?,
            exitCode: r['exitCode'] as int?,
            message: r['message'] as String?,
            stopRequested: r['stopRequested'] == true,
            logsTruncated: r['logsTruncated'] == true,
            logs: wireRows(r['logs'])
                .map(
                  (l) => WorkTaskLog(
                    l['text'] as String,
                    isStderr: l['isStderr'] == true,
                  ),
                )
                .toList(),
          ),
        )
        .toList(),
    (value) => state = value,
  );
  @override
  bool canStop(String id) => wireRows(
    hostRuntime()['tasks'],
  ).any((r) => r['id'] == id && r['canStop'] == true);
  @override
  Future<void> stop(String id) async {
    await hostRuntimeCall('tasks.stop', {'id': id});
  }
}

class HostRuntimeLogs extends WorkRuntimeLogs {
  @override
  List<WorkRuntimeLogEntry> build() => projectHostState(
    ref,
    'logs',
    (raw) => wireRows(raw).map(WorkRuntimeLogEntry.fromJson).toList(),
    (value) => state = value,
  );
  @override
  Future<void> clearConversation(String id) async {
    await hostRuntimeCall('logs.clear', {'conversation': id});
  }

  @override
  Future<void> flush() async {
    await hostRuntimeCall('logs.flush', {});
  }
}

class HostAcceptanceStore extends TaskAcceptanceStore {
  @override
  Map<String, TaskAcceptance> build() => projectHostState(
    ref,
    'acceptance',
    (raw) => wireMap(
      raw,
    ).map((k, v) => MapEntry(k, TaskAcceptance.fromJson(wireMap(v)))),
    (value) => state = value,
  );
  @override
  AcceptanceCriteria draftCriteriaForConversation(String conversationId) =>
      AcceptanceCriteria.fromJson(
        wireMap(wireMap(hostRuntime()['acceptanceDrafts'])[conversationId]),
      );
  @override
  Future<void> saveDraft(
    String conversationId,
    AcceptanceCriteria criteria,
  ) async {
    await hostRuntimeCall('acceptance.saveDraft', {
      'conversation': conversationId,
      'criteria': criteria.toJson(),
    });
  }

  @override
  Future<void> reviseByUser(String taskId, AcceptanceCriteria criteria) async {
    await hostRuntimeCall('acceptance.revise', {
      'task': taskId,
      'criteria': criteria.toJson(),
    });
  }
}

class HostWorkMemory extends WorkMemory {
  HostWorkMemory()
    : super(
        read: () => null,
        write: (_) async => throw StateError('宿主拥有工作记忆写入'),
      );
  @override
  bool get corrupt => hostRuntime()['memoryCorrupt'] == true;
  @override
  String? get corruptSource => hostRuntime()['memoryCorruptSource'] as String?;
  @override
  String? get corruptDigest => hostRuntime()['memoryCorruptDigest'] as String?;
  @override
  Map<String, dynamic> snapshot(String conversation, {String? agentId}) {
    final root = wireMap(wireMap(hostRuntime()['memory'])[conversation]);
    return agentId == null
        ? (root..remove('agents'))
        : wireMap(wireMap(root['agents'])[agentId]);
  }

  @override
  List<String> agentScopes(String conversation) => wireMap(
    wireMap(wireMap(hostRuntime()['memory'])[conversation])['agents'],
  ).keys.toList();
  @override
  Future<Map<String, dynamic>> checkpoint(
    String conversation,
    Map<String, dynamic> args, {
    bool userInitiated = false,
    String? agentId,
  }) async => wireMap(
    await hostRuntimeCall('memory.checkpoint', {
      'conversation': conversation,
      'arguments': args,
      'userInitiated': userInitiated,
      'agentId': agentId,
    }),
  );
  @override
  Future<void> repairCorrupt(
    String conversation,
    String reviewedDigest,
    String userPins,
  ) async {
    await hostRuntimeCall('memory.repair', {
      'conversation': conversation,
      'reviewedDigest': reviewedDigest,
      'userPins': userPins,
    });
  }
}

class HostRoleEvolution extends RoleEvolutionController {
  @override
  List<RoleCandidate> build() => projectHostState(
    ref,
    'roleCandidates',
    (raw) => wireRows(raw).map(RoleCandidate.fromJson).toList(),
    (value) => state = value,
  );
  @override
  Future<void> acceptEvidence(
    String id,
    int version,
    String taskId,
    String criteria,
  ) async {
    await hostRuntimeCall('roles.accept', {
      'id': id,
      'version': version,
      'taskId': taskId,
      'criteria': criteria,
    });
  }

  @override
  Future<void> revise(String id, SubagentRole role, {bool? disabled}) async {
    await hostRuntimeCall('roles.revise', {
      'id': id,
      'role': role.toJson(),
      'disabled': disabled,
      'expected_version': role.version,
    });
  }

  @override
  Future<void> rollback(String id, int version) async {
    await hostRuntimeCall('roles.rollback', {'id': id, 'version': version});
  }

  @override
  Future<void> delete(String id) async {
    await hostRuntimeCall('roles.delete', {'id': id});
  }
}

class HostWorkInsights extends WorkSessionInsightsController {
  @override
  Map<String, WorkSessionInsights> build() => projectHostState(
    ref,
    'insights',
    (raw) => wireMap(raw).map((key, value) {
      final v = wireMap(value);
      return MapEntry(
        key,
        WorkSessionInsights(
          model: v['model'] as String? ?? '',
          contextBudgetTokens: v['contextBudgetTokens'] as int?,
          messages: wireRows(v['messages']).map(decodeRequest).toList(),
          tools: wireRows(v['tools']).map(decodeTool).toList(),
          requests: wireMap(v['requests']).map(
            (id, u) => MapEntry(id, u == null ? null : decodeUsage(wireMap(u))),
          ),
          pricingKeys: Map<String, String>.from(v['pricingKeys'] as Map? ?? {}),
          requestKinds: wireMap(v['requestKinds']).map(
            (id, kind) =>
                MapEntry(id, WorkRequestKind.values.byName(kind as String)),
          ),
        ),
      );
    }),
    (value) => state = value,
  );
}

class HostModelUsage extends ModelUsageController {
  @override
  List<ModelUsageRecord> build() => projectHostState(
    ref,
    'modelUsage',
    (raw) => wireRows(
      raw,
    ).map(ModelUsageRecord.fromJson).whereType<ModelUsageRecord>().toList(),
    (value) => state = value,
  );
  @override
  void record(LlmConfig config, LlmUsage usage) {}
  @override
  Future<void> clear({String? endpoint}) async {
    await hostRuntimeCall('usage.clear', {'endpoint': endpoint});
  }

  @override
  ModelUsageRecord? find({required String endpoint, required String model}) =>
      state
          .where((r) => r.endpoint == endpoint && r.model == model)
          .firstOrNull;
  @override
  List<ModelUsageRecord> forEndpoint(String endpoint) =>
      state.where((r) => r.endpoint == endpoint).toList();
  @override
  ModelUsageRecord totals({String? endpoint}) {
    final records = endpoint == null ? state : forEndpoint(endpoint);
    return ModelUsageRecord(
      endpoint: endpoint ?? '',
      model: 'total',
      requests: records.fold(0, (n, r) => n + r.requests),
      inputTokens: records.fold(0, (n, r) => n + r.inputTokens),
      outputTokens: records.fold(0, (n, r) => n + r.outputTokens),
      cachedInputTokens: records.fold(0, (n, r) => n + r.cachedInputTokens),
      reasoningTokens: records.fold(0, (n, r) => n + r.reasoningTokens),
    );
  }
}

class HostTaskSteering extends TaskSteeringStore {
  HostTaskSteering() : super(read: (_) => null, write: (_, _) async => false);
  @override
  List<Map<String, dynamic>> snapshot(String conversation) =>
      wireRows(wireMap(hostRuntime()['steering'])[conversation]);
}
