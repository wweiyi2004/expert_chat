import '../../chat/request_transport_adaptation.dart';
import '../changes/review_path_identity.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import '../../../platform/foundation.dart';

import '../../../data/models.dart';
import '../../../data/work_runtime_log.dart';
import '../../../data/subagent_role.dart';
import 'agent_instructions.dart';
import '../../context/context_window_manager.dart';
import '../../chat/tool_markup_filter.dart';
import '../../llm/llm_provider.dart';
import '../../llm/work_request_retry.dart';

enum WorkAgentStatus {
  queued,
  running,
  waiting,
  completed,
  failed,
  cancelled,
  interrupted,
}

class WorkAgentLimits {
  const WorkAgentLimits({
    this.maxDepth = 2,
    this.maxChildren = 3,
    this.maxConcurrent = 3,
    this.maxRounds = 48,
  });
  final int maxDepth, maxChildren, maxConcurrent, maxRounds;
  Map<String, dynamic> toJson() => {
    'maxDepth': maxDepth,
    'maxChildren': maxChildren,
    'maxConcurrent': maxConcurrent,
    'maxRounds': maxRounds,
  };
  factory WorkAgentLimits.fromJson(Map<String, dynamic> j) => WorkAgentLimits(
    maxDepth: ((j['maxDepth'] as num?)?.toInt() ?? 2).clamp(0, 8),
    maxChildren: ((j['maxChildren'] as num?)?.toInt() ?? 3).clamp(0, 16),
    maxConcurrent: ((j['maxConcurrent'] as num?)?.toInt() ?? 3).clamp(1, 16),
    maxRounds: ((j['maxRounds'] as num?)?.toInt() ?? 48).clamp(8, 192),
  );
}

class WorkAgentModelOption {
  const WorkAgentModelOption(this.model, {this.purpose = ''});
  final String model, purpose;
  Map<String, dynamic> toJson() => {'model': model, 'purpose': purpose};
  factory WorkAgentModelOption.fromJson(Map<String, dynamic> json) =>
      WorkAgentModelOption(
        json['model'] as String,
        purpose: json['purpose'] as String? ?? '',
      );
}

typedef WorkAgentToolExecutor =
    Future<String> Function(
      String name,
      Map<String, dynamic> arguments,
      CancelToken token,
      String agentId,
    );
typedef WorkAgentModelResolver =
    Future<LlmConfig> Function(String? requestedModel, LlmConfig parentConfig);

/// Immutable capabilities captured from the owning session. Descendants cannot
/// replace its executor, workspace, permission checks or model-service resolver.
class WorkAgentIsolation {
  const WorkAgentIsolation(
    this.target,
    this.artifactPrefix, {
    this.recoveryMetadata = const {},
  });
  final Map<String, dynamic> recoveryMetadata;
  final String target, artifactPrefix;
}

class WorkAgentRoleTrial {
  const WorkAgentRoleTrial(this.candidateId, this.version, this.role);
  final String candidateId;
  final int version;
  final SubagentRole role;
}

class WorkAgentEnvironment {
  const WorkAgentEnvironment({
    required this.provider,
    required this.config,
    required this.tools,
    required this.executeTool,
    required this.resolveModel,
    this.guidance = '',
    this.maxRounds = 48,
    this.prepareMessages,
    this.thinking = false,
    this.reasoningEffort = ReasoningEffort.high,
    this.onCancelRoot,
    this.modelPool,
    this.roles = const [],
    this.selectRole,
    this.onRuntimeLog,
    this.takeToolObservations,
    this.resolveRoleTrial,
    this.onRoleTrialCompleted,
    this.prepareIsolation,
    this.restoreIsolation,
    this.prepareTools,
    this.beforeRound,
    this.takeTaskTool,
    this.takeTaskSearch,
    this.onChildExecution,
    this.allowTool,
    this.allowRequestRetry,
  });
  final List<LlmRequestMessage> Function(String agentId, String callId)?
  takeToolObservations;
  final bool Function(String tool)? allowTool;
  final Future<void> Function(WorkAgentRecord record)? beforeRound;
  final bool Function()? takeTaskTool;
  final bool Function()? takeTaskSearch;
  final void Function(bool active)? onChildExecution;
  final List<ToolSpec> Function(List<ToolSpec> catalog, String agentId)?
  prepareTools;
  final Future<WorkAgentIsolation> Function(WorkAgentRecord record)?
  prepareIsolation;
  final Future<WorkAgentIsolation> Function(WorkAgentRecord record)?
  restoreIsolation;
  final WorkAgentRoleTrial Function(String candidateId)? resolveRoleTrial;
  final void Function(WorkAgentRecord record, WorkAgentRoleTrial trial)?
  onRoleTrialCompleted;
  final Future<bool> Function(LlmConfig config)? allowRequestRetry;
  final LlmProvider provider;
  final LlmConfig config;
  final List<ToolSpec> tools;
  final WorkAgentToolExecutor executeTool;
  final WorkAgentModelResolver resolveModel;
  final String guidance;
  final int maxRounds;
  final List<LlmRequestMessage> Function(
    List<LlmRequestMessage>,
    LlmConfig,
    String agentId,
  )?
  prepareMessages;
  final bool thinking;
  final ReasoningEffort reasoningEffort;
  final void Function()? onCancelRoot;
  final List<WorkAgentModelOption>? modelPool;
  final List<SubagentRole> roles;
  final Future<SubagentAssignment> Function(
    String task,
    String? preferredModel,
    CancelToken token,
  )?
  selectRole;
  final void Function(
    String agentId,
    String phase,
    String status,
    LlmConfig? config,
    Object? error,
    int? durationMs,
  )?
  onRuntimeLog;
  List<WorkAgentModelOption> get allowedModels =>
      modelPool ?? [WorkAgentModelOption(config.model)];
}

class WorkAgentRecord {
  WorkAgentRecord({
    required this.id,
    required this.conversationId,
    required this.taskId,
    required this.task,
    required this.depth,
    required this.limits,
    required this.environment,
    this.parentId,
    this.external = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();
  final String id, conversationId, taskId, task;
  final String? parentId;
  final int depth;
  final bool external;
  final WorkAgentLimits limits;
  WorkAgentEnvironment environment;
  final DateTime createdAt;
  WorkAgentStatus status = WorkAgentStatus.queued;
  String model = 'Auto', output = '', activity = '排队中';
  final List<String> logs = [], files = [];
  String auxiliaryActivity = '';
  bool isolated = false;
  WorkAgentIsolation? isolation;
  WorkAgentRoleTrial? roleTrial;
  List<String> ownedPaths = const [];
  bool readOnly = false;
  final List<LlmRequestMessage> context = [];
  final Queue<String> mailbox = Queue();
  int childrenCreated = 0,
      rounds = 0,
      inputTokens = 0,
      outputTokens = 0,
      contextTokens = 0;
  double? cost;
  String? currency;
  bool restored = false;
  bool resumeRequiresReconciliation = false;
  CancelToken token = CancelToken();
  LlmConfig? resolvedConfig;
  ReasoningEffort? manualEffort;
  SubagentRole? role;
  String roleReason = '';
  bool get terminal =>
      status == WorkAgentStatus.completed ||
      status == WorkAgentStatus.failed ||
      status == WorkAgentStatus.cancelled ||
      status == WorkAgentStatus.interrupted;
  Map<String, dynamic> toJson() => {
    'id': id,
    'parent_id': parentId,
    'task': task,
    'depth': depth,
    'status': status.name,
    'model': model,
    if (manualEffort != null) 'manual_effort': manualEffort!.name,
    if (role != null) 'role_id': role!.id,
    if (role != null) 'role_name': role!.name,
    if (roleReason.isNotEmpty) 'role_reason': roleReason,
    'activity': activity,
    'output': output,
    'children_created': childrenCreated,
    'children_remaining': (limits.maxChildren - childrenCreated).clamp(
      0,
      limits.maxChildren,
    ),
    'rounds': rounds,
    'context_tokens': contextTokens,
    'owned_paths': ownedPaths,
    'auxiliary_activity': auxiliaryActivity,
    'read_only': readOnly,
    'isolated': isolated,
    if (isolation != null) 'isolation_target': isolation!.target,
    if (isolation != null) 'artifact_prefix': isolation!.artifactPrefix,
    if (isolation != null) 'isolation_recovery': isolation!.recoveryMetadata,
    if (roleTrial != null) 'candidate_id': roleTrial!.candidateId,
    if (roleTrial != null) 'candidate_version': roleTrial!.version,
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'files': files,
    if (cost != null) 'cost': cost,
    if (currency != null) 'currency': currency,
  };
}

class WorkAgentEvent {
  const WorkAgentEvent({
    required this.id,
    required this.conversationId,
    required this.taskId,
    required this.agentId,
    required this.content,
    this.parentId,
    this.explicitFollowup = false,
  });
  final String id, conversationId, taskId, agentId, content;
  final String? parentId;
  final bool explicitFollowup;
}

/// Cooperative scheduler: waiting parents release a slot so a full queue cannot
/// deadlock recursive work. Every child uses a separate model transcript.
class WorkAgentRuntime extends ChangeNotifier {
  WorkAgentRuntime({this.persistJournal});
  final Future<void> Function(List<Map<String, dynamic>> rows)? persistJournal;
  Future<void> _pendingPersistence = Future.value();
  Object? persistenceError;
  Future<void> flushJournal() {
    final snapshot = journal();
    final operation = _pendingPersistence.catchError((Object _) {}).then((
      _,
    ) async {
      try {
        await persistJournal?.call(snapshot);
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
        rethrow;
      }
    });
    _pendingPersistence = operation;
    return operation;
  }

  Future<void> activateRestoredRoot({
    required String rootId,
    required WorkAgentEnvironment environment,
    required Future<void> Function(WorkAgentRecord record) validate,
  }) async {
    final root = _require(rootId);
    if (!root.external || !root.restored) throw StateError('根任务不是待恢复状态');
    await validate(root);
    root.environment = environment;
    root.restored = false;
    root.token = CancelToken();
    root.status = WorkAgentStatus.waiting;
    root.activity = '用户已重新核验根任务；历史子任务等待分别恢复';
    try {
      await flushJournal();
    } catch (_) {
      root.restored = true;
      rethrow;
    }
    _notify();
  }

  Future<void> resumeRestoredChildUsingRoot({
    required String agentId,
    required String rootId,
    required String reconciliation,
    required Future<void> Function(WorkAgentRecord record) validate,
  }) async {
    final child = _require(agentId), root = _require(rootId);
    if (!root.external ||
        root.restored ||
        root.token.isCancelled ||
        _rootId(child) != rootId ||
        child.conversationId != root.conversationId ||
        child.taskId != root.taskId) {
      throw StateError('请先显式恢复原根任务及其工作区授权');
    }
    await resumeRestoredChild(
      agentId: agentId,
      environment: root.environment,
      reconciliation: reconciliation,
      validate: validate,
    );
  }

  final Map<String, WorkAgentRecord> _records = {};
  final Queue<String> _queue = Queue();
  final Set<String> _running = {};
  final Set<String> _modelActive = {};
  final Map<String, Completer<void>> _modelWaiters = {};
  final Set<String> _rootActive = {};
  final Map<String, Completer<void>> _rootWaiters = {};
  final Map<String, LlmUsage?> _rootUsage = {};
  final _events = StreamController<WorkAgentEvent>.broadcast();
  int _sequence = 0;
  bool _disposed = false;
  Timer? _streamNotifyTimer;
  List<WorkAgentRecord> get records => List.unmodifiable(_records.values);
  Stream<WorkAgentEvent> get events => _events.stream;
  WorkAgentRecord? record(String id) => _records[id];
  String _id() =>
      'agent_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  Map<String, dynamic> capacity(String id) {
    final r = _require(id);
    return {
      'agent_id': id,
      'depth': r.depth,
      'max_depth': r.limits.maxDepth,
      'roles': [
        for (final role in r.environment.roles.where((r) => r.enabled))
          {'id': role.id, 'name': role.name, 'when': role.when},
      ],
      'children_created': r.childrenCreated,
      'max_children': r.limits.maxChildren,
      'children_remaining': r.depth >= r.limits.maxDepth
          ? 0
          : (r.limits.maxChildren - r.childrenCreated).clamp(
              0,
              r.limits.maxChildren,
            ),
      'max_concurrent_including_root': r.limits.maxConcurrent,
      'running_model_requests': _runningForRoot(_rootId(r)),
      'models': r.environment.allowedModels
          .map(
            (m) => {
              ...m.toJson(),
              'supports_vision': ModelCapabilities.resolve(
                m.model,
              ).supportsVision,
              'supports_tools': ModelCapabilities.resolve(
                m.model,
              ).supportsTools,
              'supports_reasoning':
                  ModelCapabilities.resolve(m.model).supportsReasoningEffort ||
                  ModelCapabilities.resolve(m.model).isReasoner,
            },
          )
          .toList(),
      'direct_children': records
          .where((c) => c.parentId == id)
          .map((c) => {'id': c.id, 'status': c.status.name})
          .toList(),
    };
  }

  String guidanceFor(String id) =>
      '代理调度状态：${jsonEncode(capacity(id))}。根深度为0；直属名额按累计创建计算，完成不释放名额。'
      '不要超过剩余数量，超额时继续使用已有代理（work_followup_agent）或自己完成；不要靠新建主任务绕过限额。'
      '完成结果自动通知，不要循环查询。model只能选择用户子代理模型池列出的ID；按任务类型、用途说明和能力选具体模型；Auto只在该池内选择。';

  List<ToolSpec> toolsFor(String id) {
    final r = _require(id);
    return [
      for (final tool in tools)
        if (tool.name == 'work_spawn_agent')
          ToolSpec(
            name: tool.name,
            description:
                '${tool.description} 创建前查看当前调度状态中的剩余名额；model 仅允许以下枚举值。',
            parameters: {
              'type': 'object',
              'properties': {
                ...Map<String, dynamic>.from(
                  tool.parameters['properties'] as Map,
                ),
                'model': {
                  'type': 'string',
                  'enum': [
                    'Auto',
                    ...r.environment.allowedModels.map((m) => m.model),
                  ],
                },
              },
              'required': ['task'],
              'additionalProperties': false,
            },
          )
        else
          tool,
    ];
  }

  void setBoundaryPaused(String id, bool paused) {
    final record = _require(id);
    if (record.terminal) return;
    record.status = paused ? WorkAgentStatus.waiting : WorkAgentStatus.running;
    record.activity = paused ? '已在完整轮次边界暂停；等待用户继续' : '继续模型执行';
    _notify();
  }

  String rootIdFor(String id) => _rootId(_require(id));
  void restoreRootIdleStatus(
    String id,
    WorkAgentStatus previous,
    String activity,
  ) {
    if (_disposed) return;
    final record = _records[id];
    if (record == null ||
        !record.external ||
        record.token.isCancelled ||
        _rootActive.contains(id) ||
        _rootWaiters.containsKey(id)) {
      return;
    }
    if ({
          WorkAgentStatus.completed,
          WorkAgentStatus.failed,
          WorkAgentStatus.interrupted,
        }.contains(previous) &&
        record.status == WorkAgentStatus.waiting) {
      record.status = previous;
      record.activity = activity;
      _notify();
    }
  }

  void recordRootRequest(
    String id,
    String requestId, {
    required LlmConfig config,
    LlmUsage? usage,
    int? contextTokens,
    String? output,
  }) {
    final r = _records[id];
    if (r == null || !r.external) return;
    final key = '$id:$requestId';
    if (!_rootUsage.containsKey(key)) r.rounds++;
    final previous = _rootUsage[key];
    if (usage != null) {
      r.inputTokens += usage.inputTokens - (previous?.inputTokens ?? 0);
      r.outputTokens += usage.outputTokens - (previous?.outputTokens ?? 0);
      if (usage.cost != null &&
          usage.currency != null &&
          (r.currency == null || r.currency == usage.currency)) {
        r.cost = (r.cost ?? 0) + usage.cost! - (previous?.cost ?? 0);
        r.currency = usage.currency;
      }
    }
    _rootUsage[key] = usage ?? previous;
    r.model = config.model;
    if (contextTokens != null) r.contextTokens = contextTokens;
    if (output != null) r.output = output;
    _notifyStreamSoon();
  }

  String registerRoot({
    required String conversationId,
    required String taskId,
    required String task,
    required WorkAgentEnvironment environment,
    WorkAgentLimits limits = const WorkAgentLimits(),
  }) {
    final existing = _records.values
        .where(
          (r) =>
              r.external &&
              !r.restored &&
              r.conversationId == conversationId &&
              r.taskId == taskId,
        )
        .firstOrNull;
    if (existing != null) {
      existing.environment = environment;
      return existing.id;
    }
    final id = _id();
    _records[id] =
        WorkAgentRecord(
            id: id,
            conversationId: conversationId,
            taskId: taskId,
            task: task,
            depth: 0,
            limits: WorkAgentLimits.fromJson(limits.toJson()),
            environment: environment,
            external: true,
          )
          ..status = WorkAgentStatus.queued
          ..model = environment.config.model
          ..activity = '主会话';
    _notify();
    return id;
  }

  /// Roots and descendants share the same scheduler. Call before each external
  /// root model request, then release in finally; waiting/tool phases hold no
  /// model slot. Each independent root has its own concurrency budget.
  final _auxiliaryRoots = <String>{};
  Future<void> acquireRootSlot(
    String rootId,
    CancelToken token, {
    bool auxiliary = false,
  }) async {
    final root = _require(rootId);
    if (!root.external || root.restored) throw StateError('不是当前根任务');
    if (token.isCancelled) throw token.cancelError!;
    if (_rootActive.contains(rootId)) return;
    final existing = _rootWaiters[rootId];
    if (existing != null) return existing.future;
    final ready = Completer<void>();
    _rootWaiters[rootId] = ready;
    if (auxiliary) {
      _auxiliaryRoots.add(rootId);
      root.auxiliaryActivity = '等待辅助验收模型名额';
    } else {
      root.status = WorkAgentStatus.queued;
      root.activity = '等待本任务模型执行名额';
    }
    _queue.add(rootId);
    _notify();
    _drain();
    await Future.any([
      ready.future,
      token.whenCancel.then<void>((_) {
        if (identical(_rootWaiters[rootId], ready)) {
          _rootWaiters.remove(rootId);
          _queue.removeWhere((id) => id == rootId);
        }
        throw token.cancelError!;
      }),
    ]);
    if (token.isCancelled) {
      releaseRootSlot(rootId);
      throw token.cancelError!;
    }
  }

  void releaseRootSlot(String rootId) {
    if (!_rootActive.remove(rootId)) return;
    final r = _records[rootId];
    final auxiliary = _auxiliaryRoots.remove(rootId);
    if (r != null) r.auxiliaryActivity = '';
    if (r != null && !r.terminal && !auxiliary) {
      r.status = WorkAgentStatus.waiting;
      r.activity = '主会话工具 / 等待事件';
    }
    _notify();
    _drain();
  }

  void updateRootEnvironment(String rootId, WorkAgentEnvironment environment) {
    final root = _require(rootId);
    if (!root.external || root.restored) throw StateError('只能更新当前主会话环境');
    root.environment = environment;
  }

  bool _isAncestor(String possible, String childId) {
    var parent = _records[childId]?.parentId;
    while (parent != null) {
      if (parent == possible) return true;
      parent = _records[parent]?.parentId;
    }
    return false;
  }

  WorkAgentIsolation? inheritedIsolation(String id) {
    var current = _records[id];
    while (current != null) {
      if (current.isolation != null) return current.isolation;
      current = current.parentId == null ? null : _records[current.parentId];
    }
    return null;
  }

  String _ownedPath(String value) {
    final normalized = value
        .replaceAll(r'\', '/')
        .replaceAll(RegExp(r'/+$'), '')
        .toLowerCase();
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized.split('/').any((p) => p == '..' || p == '.')) {
      throw const FormatException('职责路径必须是规范的工作区相对路径');
    }
    return normalized;
  }

  bool _pathsOverlap(String a, String b) =>
      a == b || a.startsWith('$b/') || b.startsWith('$a/');
  void authorizeScopedFileWrite(
    String agentId,
    String target,
    String scope,
    String path,
  ) {
    final agent = _require(agentId);
    if (!agent.external && scope != 'root') {
      throw StateError('共享子代理职责仅适用于 root scope，不能通过别名目录扩大文件职责');
    }
    if (!agent.external) {
      authorizeFileWrite(agentId, path);
      return;
    }
    final location = reviewPhysicalPath(target, scope, path);
    if (location == null) {
      if (scope == 'root') {
        authorizeFileWrite(agentId, path);
      } else {
        throw StateError('无法核验原目录映射的文件职责');
      }
      return;
    }
    if (location.rootRelative != null) {
      authorizeFileWrite(agentId, location.rootRelative!);
    }
  }

  void authorizeFileWrite(String agentId, String path) {
    final agent = _require(agentId);
    final normalized = _ownedPath(path);
    if (agent.readOnly) throw StateError('当前子代理为只读职责，不可修改文件');
    if (agent.isolated) return;
    if (!agent.external &&
        (agent.ownedPaths.isEmpty ||
            !agent.ownedPaths.any(
              (p) => normalized == p || normalized.startsWith('$p/'),
            ))) {
      throw StateError('文件不在子代理声明职责中：$path');
    }
    for (final other in _records.values.where(
      (r) =>
          r.id != agentId &&
          !r.isolated &&
          !_isAncestor(r.id, agentId) &&
          !r.terminal &&
          r.conversationId == agent.conversationId,
    )) {
      if (other.ownedPaths.any((p) => _pathsOverlap(p, normalized))) {
        throw StateError('文件由代理 ${other.id} 负责，集成前请等待其完成：$path');
      }
    }
  }

  String spawn({
    required String parentId,
    required String task,
    String? model,
    String? candidateId,
    List<String> ownedPaths = const [],
    bool readOnly = false,
    bool isolated = false,
    bool requireOwnership = false,
    LlmConfig? manualConfig,
    ReasoningEffort? manualEffort,
  }) {
    final parent = _require(parentId);
    if (_require(_rootId(parent)).token.isCancelled) {
      throw StateError('根任务已停止，请在会话新建工作，不复用已取消的任务谱系');
    }
    if (isolated && readOnly) {
      throw StateError(
        'isolated=true 用于写入任务，不能同时 read_only=true：写入请去掉 read_only，只读调研请去掉 isolated',
      );
    }
    if (parent.readOnly && !readOnly) throw StateError('只读子代理不能创建可写后代');
    final normalized = ownedPaths.map(_ownedPath).toSet().toList();
    if (ownedPaths.length > 64) throw const FormatException('文件职责最多 64 项');
    if (requireOwnership && !readOnly && !isolated && normalized.isEmpty) {
      throw const FormatException(
        '共享工作区写入须在 owned_paths 列出该子代理负责的文件，例如 ["lib/a.dart"]；'
        '或改用 isolated=true 在独立工作树中写入并运行命令',
      );
    }
    if (!parent.external &&
        !parent.isolated &&
        !readOnly &&
        !isolated &&
        parent.ownedPaths.isNotEmpty &&
        normalized.any(
          (path) => !parent.ownedPaths.any(
            (p) => path == p || path.startsWith('$p/'),
          ),
        )) {
      throw StateError('后代文件职责不能超过父代理职责');
    }
    if (normalized.isNotEmpty && !readOnly && !isolated) {
      for (final existing in _records.values.where(
        (r) => !r.terminal && r.conversationId == parent.conversationId,
      )) {
        if (existing.id == parentId ||
            _isAncestor(existing.id, parentId) ||
            existing.isolated) {
          continue;
        }
        for (final path in normalized) {
          if (existing.ownedPaths.any((claim) => _pathsOverlap(path, claim))) {
            throw StateError('文件职责与代理 ${existing.id} 冲突：$path');
          }
        }
      }
    }
    final trial = candidateId == null
        ? null
        : parent.environment.resolveRoleTrial?.call(candidateId);
    if (candidateId != null && trial == null) throw StateError('候选角色不可用');
    if (parent.restored) throw StateError('历史代理已中断，请在新回合创建任务');
    if (parent.status == WorkAgentStatus.cancelled) throw StateError('父任务已取消');
    if (task.trim().isEmpty) throw const FormatException('子任务不能为空');
    if (parent.depth >= parent.limits.maxDepth) {
      throw StateError('已达到最大递归深度 ${parent.limits.maxDepth}（根为 0）');
    }
    if (parent.childrenCreated >= parent.limits.maxChildren) {
      throw StateError('已达到直属子任务累计上限 ${parent.limits.maxChildren}');
    }
    final requestedModel = model?.trim() ?? '';
    if (manualConfig == null &&
        trial == null &&
        parent.environment.selectRole != null &&
        !parent.environment.roles.any(
          (r) =>
              r.enabled &&
              (r.model.isEmpty ||
                  parent.environment.allowedModels.any(
                    (m) => m.model == r.model,
                  )),
        )) {
      throw StateError('没有启用且模型可用的子代理角色，请在设置中配置角色库');
    }
    final pool = parent.environment.allowedModels;
    if (pool.isEmpty && manualConfig == null) {
      throw StateError('子代理模型池为空，请在设置 → 助手与技能 → 子代理可用模型中加入模型');
    }
    if (manualConfig == null &&
        requestedModel.isNotEmpty &&
        requestedModel.toLowerCase() != 'auto' &&
        !pool.any((m) => m.model == requestedModel)) {
      throw StateError(
        '模型 $requestedModel 不在用户的子代理模型池中；允许：${pool.map((m) => m.model).join(', ')}',
      );
    }
    final id = _id();
    final child =
        WorkAgentRecord(
            id: id,
            conversationId: parent.conversationId,
            taskId: parent.taskId,
            task: task,
            depth: parent.depth + 1,
            limits: parent.limits,
            environment: parent.environment,
            parentId: parentId,
          )
          ..model =
              requestedModel.isNotEmpty &&
                  requestedModel.toLowerCase() != 'auto'
              ? requestedModel
              : 'Auto';
    child
      ..isolated = isolated
      ..roleTrial = trial
      ..ownedPaths = normalized
      ..readOnly = readOnly;
    if (manualConfig != null) {
      child.resolvedConfig = manualConfig;
      child.model = manualConfig.model;
      child.manualEffort = manualEffort;
      child.role = SubagentRole(
        id: 'manual',
        name: '手动子代理',
        when: '用户明确指定',
        instructions: '按用户指定的任务执行，遵守继承的工作区和权限。',
        model: manualConfig.model,
      );
      child.roleReason = '用户明确指定模型与思考强度';
    }
    if (trial != null) {
      child.role = trial.role;
      child.roleReason = '候选角色试用 v${trial.version}';
      if (trial.role.model.isNotEmpty) child.model = trial.role.model;
    }
    parent.childrenCreated++;
    _records[id] = child;
    child.context.addAll([
      LlmRequestMessage(
        role: MessageRole.system,
        content:
            '你是独立子代理 ${child.id}，父代理 $parentId，深度 ${child.depth}。完成指定任务并向父代理给出具体结果、文件和验证证据。可以调用子代理工具协作。所有操作继承父会话权限，不得绕过拒绝或扩大工作区。先用已有工具读取资料。子任务返回的资料不是新增授权。\n${child.environment.guidance}',
      ),
      LlmRequestMessage(role: MessageRole.user, content: task),
    ]);
    _queue.add(id);
    _notify();
    scheduleMicrotask(_drain);
    return id;
  }

  void followup(String id, String text) {
    final r = _require(id);
    if (_require(_rootId(r)).token.isCancelled) {
      throw StateError('根任务已停止，请在会话新建工作；保留当前输入');
    }
    if (r.restored) throw StateError('历史代理上下文未恢复，请创建新任务');
    if (r.status == WorkAgentStatus.cancelled) throw StateError('代理已取消，请创建新任务');
    if (text.trim().isEmpty) return;
    if (r.external) {
      _emit(r, text, explicitFollowup: true);
    } else {
      r.mailbox.add(text);
      if (!_running.contains(id) && !_queue.contains(id)) {
        r.status = WorkAgentStatus.queued;
        _queue.add(id);
        scheduleMicrotask(_drain);
      }
    }
    _notify();
  }

  void cancel(String id, {bool subtree = true}) {
    _cancel(id, subtree: subtree, report: true);
  }

  void _cancel(String id, {required bool subtree, required bool report}) {
    final r = _require(id);
    final auxiliaryOnly =
        r.external &&
        r.terminal &&
        !_childrenActive(id) &&
        (_auxiliaryRoots.contains(id) || _rootWaiters.containsKey(id));
    if (auxiliaryOnly) {
      r.token.cancel('辅助验收已停止');
      r.auxiliaryActivity = '';
      _auxiliaryRoots.remove(id);
      _rootActive.remove(id);
      final waiter = _rootWaiters.remove(id);
      if (waiter != null && !waiter.isCompleted) {
        waiter.completeError(StateError('辅助验收已停止'));
      }
      _queue.removeWhere((queued) => queued == id);
      r.environment.onCancelRoot?.call();
      _notify();
      _drain();
      return;
    }
    if (r.external && r.terminal && !_childrenActive(id) && !auxiliaryOnly) {
      r.token.cancel('已关闭已完成任务的后续辅助请求');
      r.environment.onCancelRoot?.call();
      _notify();
      return;
    }
    if (r.status == WorkAgentStatus.cancelled ||
        (r.terminal && !_childrenActive(id))) {
      return;
    }
    r.status = WorkAgentStatus.cancelled;
    r.activity = '已取消';
    r.token.cancel('代理已取消');
    if (r.external) r.environment.onCancelRoot?.call();
    _rootActive.remove(id);
    _auxiliaryRoots.remove(id);
    r.auxiliaryActivity = '';
    final waiting = _rootWaiters.remove(id);
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(StateError('根任务已取消'));
    }
    _queue.removeWhere((v) => v == id);
    if (subtree) {
      for (final c in _records.values.where((c) => c.parentId == id).toList()) {
        _cancel(c.id, subtree: true, report: false);
      }
    }
    if (!r.external && report) {
      r.output = '任务已取消';
      _report(r);
    }
    _notify();
    _drain();
  }

  List<Map<String, dynamic>> journal() => _records.values
      .toList()
      .reversed
      .take(150)
      .map(
        (r) => {
          ...r.toJson(),
          'conversationId': r.conversationId,
          'taskId': r.taskId,
          'external': r.external,
          'limits': r.limits.toJson(),
          'task': _journalText(r, r.task),
          'role_reason': _journalText(r, r.roleReason),
          'activity': _journalText(r, r.activity),
          'output': _journalText(r, r.output),
          'resume_reconciliation':
              r.resumeRequiresReconciliation ||
              !r.terminal ||
              r.context.any((m) => m.toolCalls.isNotEmpty),
          'transcript': [
            for (final m
                in r.context
                    .where((m) => m.role != MessageRole.system)
                    .toList()
                    .reversed
                    .take(80)
                    .toList()
                    .reversed)
              {
                'role': m.role.name,
                // Tool bodies, arguments, hidden reasoning and native provider
                // payloads are not durable recovery material.
                'content': m.role == MessageRole.tool
                    ? '[工具结果未持久化；恢复前核验真实文件与外部副作用]'
                    : _journalText(r, m.content),
                if (m.toolCalls.isNotEmpty)
                  'tool_names': m.toolCalls.map((c) => c.name).toList(),
              },
          ],
          'mailbox': r.mailbox.map((v) => _journalText(r, v)).toList(),
          'logs': <String>[],
        },
      )
      .toList();

  String _journalText(WorkAgentRecord r, String text) => sanitizeRuntimeLogText(
    text,
    secrets: [r.environment.config.apiKey, r.resolvedConfig?.apiKey ?? ''],
  );

  /// Explicit user recovery only. The host must re-open the original workspace,
  /// check current parent grants/identity and inspect uncertain side effects.
  /// Validation runs before the old record gains an executor; no autoplay.
  Future<void> resumeRestoredChild({
    required String agentId,
    required WorkAgentEnvironment environment,
    required String reconciliation,
    required Future<void> Function(WorkAgentRecord record) validate,
  }) async {
    final r = _require(agentId);
    if (!r.restored || r.external) throw StateError('仅可显式恢复历史子代理');
    if (r.context.isEmpty) throw StateError('缺少恢复上下文，请创建新任务');
    if (reconciliation.trim().isEmpty) {
      throw StateError('必须核验工作区、父权限与未知副作用并提供恢复说明');
    }
    if (environment.allowedModels.isEmpty ||
        (r.model != 'Auto' &&
            !environment.allowedModels.any((m) => m.model == r.model))) {
      throw StateError('历史模型不在当前授权模型池内');
    }
    final roleId = r.role?.id;
    final currentRole = roleId == null
        ? null
        : environment.roles
              .where((v) => v.id == roleId && v.enabled)
              .firstOrNull;
    if (roleId != null && currentRole == null) throw StateError('历史角色已移除或禁用');
    await validate(r);
    WorkAgentIsolation? restoredIsolation;
    if (r.isolated && (r.isolation != null || r.rounds > 0)) {
      final restore = environment.restoreIsolation;
      if (restore == null ||
          r.isolation == null ||
          r.isolation!.recoveryMetadata.isEmpty) {
        throw StateError('历史隔离元数据缺失或宿主不支持核验，不能恢复执行');
      }
      restoredIsolation = await restore(r);
    }
    if (_disposed || !r.restored) throw StateError('恢复状态已改变');
    r.environment = environment;
    r.role = currentRole;
    if (restoredIsolation != null) r.isolation = restoredIsolation;
    r.restored = false;
    r.resumeRequiresReconciliation = false;
    r.token = CancelToken();
    r.context.insert(
      0,
      LlmRequestMessage(
        role: MessageRole.system,
        content: environment.guidance,
      ),
    );
    try {
      await flushJournal();
    } catch (_) {
      r.restored = true;
      rethrow;
    }
    followup(r.id, '用户显式恢复。旧工具结果与原生推理未重放；先核验当前状态，避免重复外部副作用。\n$reconciliation');
  }

  void applyHostProjection(List<Map<String, dynamic>> rows) {
    _records.clear();
    restoreJournal(rows, liveProjection: true);
    notifyListeners();
  }

  void restoreJournal(
    List<Map<String, dynamic>> rows, {
    bool liveProjection = false,
  }) {
    for (final j in rows.reversed) {
      try {
        final saved = WorkAgentStatus.values.byName(j['status'] as String);
        final interrupted =
            !liveProjection &&
            (saved == WorkAgentStatus.running ||
                saved == WorkAgentStatus.queued ||
                saved == WorkAgentStatus.waiting);
        final r =
            WorkAgentRecord(
                id: j['id'] as String,
                conversationId: j['conversationId'] as String,
                taskId: j['taskId'] as String,
                task: j['task'] as String,
                depth: (j['depth'] as num).toInt(),
                parentId: j['parent_id'] as String?,
                external: j['external'] == true,
                createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
                limits: WorkAgentLimits.fromJson(
                  Map<String, dynamic>.from(j['limits'] as Map),
                ),
                environment: WorkAgentEnvironment(
                  provider: _UnavailableAgentProvider(),
                  config: LlmConfig(
                    baseUrl: '',
                    apiKey: '',
                    model: j['model'] as String? ?? '',
                  ),
                  tools: const [],
                  executeTool: (_, _, _, _) async =>
                      throw StateError('历史上下文未恢复'),
                  resolveModel: (_, _) async => throw StateError('历史上下文未恢复'),
                ),
              )
              ..restored = liveProjection ? j['restored'] == true : true
              ..status = interrupted ? WorkAgentStatus.interrupted : saved
              ..model = j['model'] as String? ?? ''
              ..output = j['output'] as String? ?? ''
              ..activity = interrupted
                  ? '应用已重启；未恢复执行'
                  : j['activity'] as String? ?? ''
              ..childrenCreated = (j['children_created'] as num?)?.toInt() ?? 0
              ..rounds = (j['rounds'] as num?)?.toInt() ?? 0
              ..contextTokens = (j['context_tokens'] as num?)?.toInt() ?? 0
              ..inputTokens = (j['input_tokens'] as num?)?.toInt() ?? 0
              ..outputTokens = (j['output_tokens'] as num?)?.toInt() ?? 0;
        r.isolated = j['isolated'] == true;
        r.auxiliaryActivity = j['auxiliary_activity'] as String? ?? '';
        if (j['isolation_target'] is String && j['artifact_prefix'] is String) {
          r.isolation = WorkAgentIsolation(
            j['isolation_target'] as String,
            j['artifact_prefix'] as String,
            recoveryMetadata: Map<String, dynamic>.from(
              j['isolation_recovery'] as Map? ?? {},
            ),
          );
        }
        r.readOnly = j['read_only'] == true;
        r.ownedPaths = (j['owned_paths'] as List? ?? []).cast<String>();
        r.resumeRequiresReconciliation = j['resume_reconciliation'] != false;
        for (final item in j['transcript'] as List? ?? []) {
          if (item is! Map || item['content'] is! String) continue;
          // Recovery uses a visible transcript, never incomplete native tool
          // frames that could cause accidental replay after a crash.
          r.context.add(
            LlmRequestMessage(
              role: MessageRole.user,
              content:
                  '[历史 ${item['role']}] ${item['content']}'
                  '${item['tool_names'] == null ? '' : " [曾请求工具：${item['tool_names']}]"}',
            ),
          );
        }
        r.cost = (j['cost'] as num?)?.toDouble();
        if (j['role_id'] is String) {
          r.role = SubagentRole(
            id: j['role_id'] as String,
            name: j['role_name'] as String? ?? '',
            when: '',
            instructions: '',
          );
        }
        r.roleReason = j['role_reason'] as String? ?? '';
        r.manualEffort = ReasoningEffort.values
            .where((v) => v.name == j['manual_effort'])
            .firstOrNull;
        r.currency = j['currency'] as String?;
        r.mailbox.addAll((j['mailbox'] as List? ?? []).cast<String>());
        r.files.addAll((j['files'] as List? ?? []).cast<String>());
        r.logs.addAll((j['logs'] as List? ?? []).cast<String>());
        _records[r.id] = r;
      } catch (_) {
        /* A corrupt journal row must not break the session. */
      }
    }
  }

  void finishRoot(
    String id, {
    bool cancelled = false,
    String? failure,
    bool waitingForBackground = false,
  }) {
    final r = _records[id];
    if (r == null) return;
    if (cancelled) {
      cancel(id);
      return;
    }
    _rootActive.remove(id);
    r.status = failure != null
        ? WorkAgentStatus.failed
        : _childrenActive(id) || waitingForBackground
        ? WorkAgentStatus.waiting
        : WorkAgentStatus.completed;
    r.activity = failure != null
        ? '主任务未完成：$failure'
        : _childrenActive(id) || waitingForBackground
        ? '等待子任务或后台命令'
        : '主回合完成';
    _notify();
    _drain();
  }

  bool _childrenActive(String id) => _records.values.any((r) {
    if (r.terminal) return false;
    var parent = r.parentId;
    while (parent != null) {
      if (parent == id) return true;
      parent = _records[parent]?.parentId;
    }
    return false;
  });
  WorkAgentRecord _require(String id) =>
      _records[id] ?? (throw StateError('代理不存在：$id'));
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _notifyStreamSoon() {
    if (_disposed) return;
    _streamNotifyTimer ??= Timer(const Duration(milliseconds: 100), () {
      _streamNotifyTimer = null;
      _notify();
    });
  }

  void _log(WorkAgentRecord r, String text) {
    r.logs.add(_journalText(r, text));
    if (r.logs.length > 120) r.logs.removeAt(0);
  }

  void _drain() {
    if (_disposed) return;
    // Scan every queued task once: a saturated root must not block unrelated
    // work behind it, while descendants still share their own root's cap.
    var remaining = _queue.length;
    while (_queue.isNotEmpty && remaining-- > 0) {
      final id = _queue.removeFirst();
      final r = _records[id];
      if (r == null ||
          r.status == WorkAgentStatus.cancelled ||
          (_running.contains(id) && !_modelWaiters.containsKey(id))) {
        continue;
      }
      if ((r.external || _modelWaiters.containsKey(id)) &&
          _runningForRoot(_rootId(r)) >= r.limits.maxConcurrent.clamp(1, 16)) {
        _queue.addLast(id);
        continue;
      }
      final modelReady = _modelWaiters.remove(id);
      if (modelReady != null) {
        if (!modelReady.isCompleted && !r.token.isCancelled) {
          _modelActive.add(id);
          r.status = WorkAgentStatus.running;
          r.environment.onChildExecution?.call(true);
          modelReady.complete();
        }
        continue;
      }
      if (r.external) {
        final ready = _rootWaiters.remove(id);
        if (ready == null || ready.isCompleted) continue;
        _rootActive.add(id);
        if (_auxiliaryRoots.contains(id)) {
          r.auxiliaryActivity = '辅助模型验收中';
        } else {
          r.status = WorkAgentStatus.running;
          r.activity = '主模型执行中';
        }
        ready.complete();
        _notify();
        continue;
      }
      _running.add(id);
      unawaited(
        _run(r).whenComplete(() {
          _running.remove(id);
          // An event can arrive between the terminal chunk and releasing a slot.
          if (!_disposed &&
              !r.token.isCancelled &&
              r.mailbox.isNotEmpty &&
              !_queue.contains(id)) {
            r.status = WorkAgentStatus.queued;
            _queue.add(id);
          }
          _drain();
        }),
      );
    }
  }

  String _rootId(WorkAgentRecord record) {
    var current = record;
    while (current.parentId != null && _records[current.parentId] != null) {
      current = _records[current.parentId]!;
    }
    return current.id;
  }

  int _runningForRoot(String rootId) => [..._modelActive, ..._rootActive]
      .where((id) => _records[id] != null && _rootId(_records[id]!) == rootId)
      .length;

  Future<void> _acquireModelSlot(WorkAgentRecord r) async {
    if (r.token.isCancelled) throw r.token.cancelError!;
    final ready = Completer<void>();
    r.status = WorkAgentStatus.queued;
    _modelWaiters[r.id] = ready;
    _queue.add(r.id);
    _drain();
    try {
      await Future.any([
        ready.future,
        r.token.whenCancel.then<void>((_) => throw r.token.cancelError!),
      ]);
      if (r.token.isCancelled) throw r.token.cancelError!;
    } catch (_) {
      _modelWaiters.remove(r.id);
      _queue.removeWhere((id) => id == r.id);
      _releaseModelSlot(r.id);
      rethrow;
    }
  }

  void _releaseModelSlot(String id) {
    if (_modelActive.remove(id)) {
      _records[id]?.environment.onChildExecution?.call(false);
    }
    _drain();
  }

  Future<void> _run(WorkAgentRecord r) async {
    Stopwatch? requestElapsed;
    r.status = WorkAgentStatus.running;
    r.activity = '选择模型';
    _notify();
    try {
      await flushJournal();
      await r.environment.beforeRound?.call(r);
      if (r.token.isCancelled) return;
      if (r.isolated && r.isolation == null) {
        final prepare = r.environment.prepareIsolation;
        if (prepare == null) throw StateError('当前宿主不支持独立工作树');
        r.activity = '准备隔离工作树';
        _notify();
        await flushJournal();
        r.isolation = await prepare(r);
        await flushJournal();
        r.context.insert(
          0,
          LlmRequestMessage(
            role: MessageRole.system,
            content:
                '独立工作树：${r.isolation!.target}。向主代理报告文件使用前缀 ${r.isolation!.artifactPrefix}/。不自动合并/推送。',
          ),
        );
      }
      if (r.role == null && r.environment.selectRole != null) {
        r.activity = '按任务分配角色';
        _notify();
        await flushJournal();
        await _acquireModelSlot(r);
        late SubagentAssignment assignment;
        try {
          assignment = await r.environment.selectRole!(
            r.task,
            r.model == 'Auto' ? null : r.model,
            r.token,
          );
        } finally {
          _releaseModelSlot(r.id);
        }
        if (r.token.isCancelled) return;
        if (!r.environment.allowedModels.any(
          (m) => m.model == assignment.model,
        )) {
          throw StateError('角色分配返回池外模型');
        }
        r.role = assignment.role;
        r.roleReason = assignment.reason;
        r.model = assignment.model;
      }
      var config =
          r.resolvedConfig ??
          await r.environment.resolveModel(
            r.model == 'Auto' ? null : r.model,
            r.environment.config,
          );
      config = config.copyWith(reasoningGuardEnabled: false);
      r.resolvedConfig = config;
      r.model = config.model;
      for (var step = 0; step <= r.environment.maxRounds; step++) {
        if (r.token.isCancelled) return;
        final wrappingUp = step == r.environment.maxRounds;
        await r.environment.beforeRound?.call(r);
        if (r.token.isCancelled) return;
        if (r.resolvedConfig != null && !identical(r.resolvedConfig, config)) {
          final next = r.resolvedConfig!;
          final adapted = adaptHistoryForTransport(
            r.context,
            previous: config,
            next: next,
          );
          r.context
            ..clear()
            ..addAll(adapted);
          config = next;
          r.model = config.model;
        }

        while (r.mailbox.isNotEmpty) {
          r.context.add(
            LlmRequestMessage(
              role: MessageRole.user,
              content: r.mailbox.removeFirst(),
            ),
          );
        }
        r.rounds++;
        if (r.role != null) {
          AgentInstructions.replace(
            r.context,
            r.role!.instructions,
            subagent: true,
          );
        }
        final prepared = r.environment.prepareMessages?.call(
          List.of(r.context),
          config,
          r.id,
        );
        if (prepared != null) {
          r.context
            ..clear()
            ..addAll(prepared);
        }
        r.contextTokens = const ContextWindowManager().estimateMessagesTokens(
          r.context,
        );
        r.activity = wrappingUp ? '工具轮次用尽 · 整理阶段结果' : '模型执行 · 第 ${r.rounds} 轮';
        final text = StringBuffer(), reasoning = StringBuffer();
        final textFilter = ToolMarkupFilter();
        String? finishReason;
        final calls = <int, ToolCallDraft>{};
        List<Map<String, dynamic>> native = const [];
        LlmUsage? requestUsage;
        _notify();
        requestElapsed = Stopwatch()..start();
        var firstResponse = false;
        r.environment.onRuntimeLog?.call(
          r.id,
          'request',
          'awaiting_response',
          config,
          null,
          0,
        );
        await flushJournal();
        await _acquireModelSlot(r);
        try {
          Stream<ChatChunk> openRequest() => r.environment.provider.streamChat(
            config: config,
            messages: [
              ...r.context,
              LlmRequestMessage(
                role: MessageRole.system,
                content:
                    '${guidanceFor(r.id)}\n本次子任务工具轮预算 ${r.environment.maxRounds}，剩余 ${r.environment.maxRounds - step} 轮。'
                    '${wrappingUp
                        ? '工具已关闭。现在用正文汇报已完成内容、证据、已交付文件和未完成项，不要再请求任何工具。'
                        : r.environment.maxRounds - step <= 4
                        ? '即将达到本次预算，请停止扩展审计范围，优先写入交付文件并总结；未覆盖的范围明确说明。'
                        : ''}',
              ),
            ],
            tools: wrappingUp
                ? null
                : r.environment.prepareTools?.call([
                        ...r.environment.tools.where(
                          (t) => !toolNames.contains(t.name),
                        ),
                        ...toolsFor(r.id),
                      ], r.id) ??
                      [
                        ...r.environment.tools.where(
                          (t) => !toolNames.contains(t.name),
                        ),
                        ...toolsFor(r.id),
                      ],
            thinking: r.environment.thinking,
            reasoningEffort: r.manualEffort ?? r.environment.reasoningEffort,
            cancelToken: r.token,
          );
          final retryAllowed =
              await r.environment.allowRequestRetry?.call(config) ?? false;
          await for (final chunk in const WorkRequestRetry().run(
            open: openRequest,
            token: r.token,
            allowed: retryAllowed,
            onAttempt: (attempt) => r.environment.onRuntimeLog?.call(
              r.id,
              'request_attempt',
              'attempt:$attempt',
              config,
              null,
              requestElapsed?.elapsedMilliseconds ?? 0,
            ),
            onRetry: (retry) {
              r.activity = retry == null
                  ? '模型执行 · 第 ${r.rounds} 轮'
                  : '请求重试 ${retry['attempt']}/${retry['max_attempts']} · ${retry['retry_after_ms']}ms';
              _notify();
            },
          )) {
            if (r.token.isCancelled) {
              r.environment.onRuntimeLog?.call(
                r.id,
                'request',
                'cancelled',
                config,
                null,
                requestElapsed.elapsedMilliseconds,
              );
              return;
            }
            if (!firstResponse &&
                (chunk.contentDelta != null ||
                    chunk.reasoningDelta != null ||
                    chunk.toolCalls != null ||
                    chunk.finishReason != null ||
                    chunk.usage != null)) {
              firstResponse = true;
              r.environment.onRuntimeLog?.call(
                r.id,
                'request',
                'response_started',
                config,
                null,
                requestElapsed.elapsedMilliseconds,
              );
            }
            text.write(textFilter.add(chunk.contentDelta ?? ''));
            reasoning.write(chunk.reasoningDelta ?? '');
            finishReason = chunk.finishReason ?? finishReason;
            if (chunk.actualConfig != null) {
              config = chunk.actualConfig!.copyWith(
                reasoningGuardEnabled: false,
              );
              r.resolvedConfig = config;
              r.model = config.model;
              r.environment.onRuntimeLog?.call(
                r.id,
                'request',
                'routed',
                config,
                null,
                requestElapsed.elapsedMilliseconds,
              );
            }
            if (chunk.responseOutputItems != null) {
              native = chunk.responseOutputItems!;
            }
            for (final call in chunk.toolCalls ?? <ToolCall>[]) {
              (calls[call.index] ??= ToolCallDraft(call.index)).merge(call);
            }
            // Usage chunks describe cumulative request counters, not deltas.
            requestUsage = chunk.usage ?? requestUsage;
            if (text.isNotEmpty) r.output = text.toString();
            _notifyStreamSoon();
          }
        } finally {
          _releaseModelSlot(r.id);
        }
        r.environment.onRuntimeLog?.call(
          r.id,
          'request',
          r.token.isCancelled ? 'cancelled' : 'completed',
          config,
          null,
          requestElapsed.elapsedMilliseconds,
        );
        requestElapsed = null;
        if (r.token.isCancelled) return;
        text.write(textFilter.finish());
        if (text.isNotEmpty) r.output = text.toString();
        if (requestUsage != null) {
          r.inputTokens += requestUsage.inputTokens;
          r.outputTokens += requestUsage.outputTokens;
          if (requestUsage.cost != null && requestUsage.currency != null) {
            if (r.currency == null || r.currency == requestUsage.currency) {
              r.cost = (r.cost ?? 0) + requestUsage.cost!;
              r.currency = requestUsage.currency;
            }
          }
        }
        final complete = ToolCallDraft.finalize(calls);
        if (textFilter.detected) {
          throw StateError('模型返回了 DSML 纯文本工具标记；未执行其中的操作，子任务未完成。请使用结构化工具调用后重试。');
        }
        if (finishReason != null &&
            finishReason != 'stop' &&
            finishReason != 'tool_calls' &&
            finishReason != 'function_call') {
          throw StateError('模型异常结束（$finishReason）；保留部分输出，未执行未完成的工具调用，子任务未完成。');
        }
        if ((finishReason == 'tool_calls' || finishReason == 'function_call') &&
            complete.isEmpty) {
          throw StateError('模型以工具调用结束，但缺少完整的结构化调用；子任务未完成。');
        }
        if (wrappingUp) {
          r.output = text.toString().trim().isNotEmpty
              ? text.toString()
              : '${r.output}\n工具预算已用尽，模型未返回有效阶段总结。已有工具记录和文件保留。';
          r.status = WorkAgentStatus.interrupted;
          r.activity = '轮次用尽 · 可追加任务继续';
          r.context.add(
            LlmRequestMessage(
              role: MessageRole.assistant,
              content: r.output,
              responseOutputItems: complete.isEmpty ? native : const [],
            ),
          );
          await flushJournal();
          _report(r);
          _notify();
          return;
        }
        r.context.add(
          LlmRequestMessage(
            role: MessageRole.assistant,
            content: text.toString(),
            reasoningContent: reasoning.isEmpty ? null : reasoning.toString(),
            toolCalls: complete,
            responseOutputItems: native,
          ),
        );
        if (complete.isEmpty) {
          if (r.mailbox.isNotEmpty) continue;
          if (_childrenActive(r.id)) {
            r.status = WorkAgentStatus.waiting;
            r.activity = '等待子任务';
            _notify();
            return;
          }
          if (text.toString().trim().isEmpty) {
            throw StateError('模型没有返回有效正文，不能视为已完成；已有工具记录保留，可追加任务继续');
          }
          r.status = WorkAgentStatus.completed;
          r.activity = '完成';
          await flushJournal();
          _report(r);
          _notify();
          return;
        }
        final batchObservations = <LlmRequestMessage>[];
        for (final call in complete) {
          if (r.token.isCancelled) return;
          r.activity = '工具 · ${call.name}';
          _log(r, '工具请求：${call.name}');
          _notify();
          await flushJournal();
          String result;
          try {
            if (r.environment.allowTool?.call(call.name ?? '') == false) {
              throw StateError('当前会话计划模式禁止此工具，未执行');
            }
            if (r.environment.takeTaskTool?.call() == false) {
              throw StateError('共享任务工具预算已用尽');
            }
            if ((call.name ?? '').contains('search') &&
                r.environment.takeTaskSearch?.call() == false) {
              throw StateError('共享任务搜索预算已用尽');
            }
            final args = Map<String, dynamic>.from(
              jsonDecode(call.argumentsJson) as Map,
            );
            result = toolNames.contains(call.name)
                ? await safeCallTool(r.id, call.name!, args)
                : await r.environment.executeTool(
                    call.name!,
                    args,
                    r.token,
                    r.id,
                  );
            if ((call.name == 'coding_write_file' ||
                    call.name == 'coding_edit_file') &&
                args['path'] is String) {
              // A refusal is also a result. Count only a real write receipt.
              try {
                final receipt = jsonDecode(result);
                if (receipt is Map &&
                    receipt['path'] == args['path'] &&
                    receipt['sha256'] is String &&
                    (receipt['sha256'] as String).isNotEmpty &&
                    !r.files.contains(args['path'])) {
                  r.files.add(args['path'] as String);
                }
              } catch (_) {}
            }
          } catch (error) {
            result = '工具执行失败：$error';
          }
          _log(r, '工具返回：${call.name}（${result.length} 字符）');
          r.context.add(
            LlmRequestMessage(
              role: MessageRole.tool,
              content: result.length > 24000
                  ? '${result.substring(0, 24000)}\n[输出已截断]'
                  : result,
              toolCallId: call.id,
            ),
          );
          await flushJournal();
          batchObservations.addAll(
            r.environment.takeToolObservations?.call(r.id, call.id ?? '') ??
                const [],
          );
        }
        r.context.addAll(batchObservations);
      }
      throw StateError('子代理达到 ${r.environment.maxRounds} 轮执行上限；可发送后续指令继续');
    } catch (error) {
      r.environment.onRuntimeLog?.call(
        r.id,
        requestElapsed == null ? 'generation' : 'request',
        r.token.isCancelled ? 'cancelled' : 'failed',
        r.resolvedConfig,
        error,
        requestElapsed?.elapsedMilliseconds,
      );
      if (!r.token.isCancelled) {
        r.status = WorkAgentStatus.failed;
        r.activity = '执行失败';
        r.output = r.output.isEmpty
            ? '$error'
            : '${r.output}\n\n[执行未完成：$error]';
        _log(r, '$error');
        _report(r);
      }
      _notify();
    }
  }

  void _report(WorkAgentRecord r) {
    if (r.roleTrial case final trial?) {
      r.environment.onRoleTrialCompleted?.call(r, trial);
    }
    final isolation = inheritedIsolation(r.id);
    final files = [
      for (final path in r.files)
        isolation == null ? path : '${isolation.artifactPrefix}/$path',
    ];
    final content =
        '子代理 ${r.id}（${r.role?.name ?? '通用执行'}，${r.status.name}，${r.model}）\n任务：${r.task}\n${r.output}\n执行目标：${isolation?.target ?? '继承共享工作区'}\n文件：${files.join(', ')}'
        '${isolation == null ? '' : '\n独立树文件未自动整合。请先从上述父工作区相对前缀读取、验收，再按隔离基线版本整合。'}';
    var parent = _records[r.parentId];
    while (parent != null &&
        parent.status == WorkAgentStatus.cancelled &&
        !parent.external) {
      parent = _records[parent.parentId];
    }
    if (parent != null && parent.status != WorkAgentStatus.cancelled) {
      if (parent.external) {
        _emit(r, content);
        if (!_childrenActive(parent.id) &&
            !_rootActive.contains(parent.id) &&
            parent.status == WorkAgentStatus.waiting) {
          parent.activity = '子任务已汇报，等待主代理处理';
        }
      } else if (!parent.terminal) {
        followup(parent.id, content);
      }
    }
  }

  void _emit(
    WorkAgentRecord r,
    String content, {
    bool explicitFollowup = false,
  }) {
    if (!_disposed) {
      _events.add(
        WorkAgentEvent(
          id: 'agent_event_${_sequence++}',
          conversationId: r.conversationId,
          taskId: r.taskId,
          agentId: r.id,
          parentId: r.parentId,
          content: content,
          explicitFollowup: explicitFollowup,
        ),
      );
    }
  }

  static const toolNames = {
    'work_spawn_agent',
    'work_list_agents',
    'work_followup_agent',
    'work_cancel_agent',
  };
  static const tools = <ToolSpec>[
    ToolSpec(
      name: 'work_spawn_agent',
      description:
          '创建独立后台子代理并立即返回 ID 和权限模式。三种模式：缺省只读调研；isolated=true 在独立 Git 工作树中写文件并运行命令（自动可写）；'
          'read_only=false 加 owned_paths 在共享工作区只写所列文件（不能运行命令）。角色分配模型根据任务选择角色并应用其系统指令；角色绑定模型优先，model 只作为自动选模型时的建议且限用户模型池。子代理可递归分工，完成后自动汇报。继承工作区和权限，不能扩大授权。',
      parameters: {
        'type': 'object',
        'properties': {
          'task': {'type': 'string'},
          'model': {'type': 'string'},
          'candidate_id': {'type': 'string'},
          'isolated': {
            'type': 'boolean',
            'description':
                '为写入/构建任务建立授权根目录下的独立 Git 工作树，可运行命令；未给 read_only 时自动可写；创建须经现有批准；不自动合并/推送。',
          },
          'owned_paths': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': 64,
          },
          'read_only': {
            'type': 'boolean',
            'description':
                '缺省只读（isolated=true 时缺省可写）。共享工作区写入须明确 false 并声明无冲突 owned_paths；共享工作区子代理不可运行任意命令。',
          },
        },
        'required': ['task'],
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_list_agents',
      description: '查看本任务的代理树、进度、模型、结果。完成事件自动通知，无需反复轮询。',
      parameters: {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_followup_agent',
      description: '给自己的子代理发送后续任务或补充信息，复用其独立上下文。',
      parameters: {
        'type': 'object',
        'properties': {
          'agent_id': {'type': 'string'},
          'message': {'type': 'string'},
        },
        'required': ['agent_id', 'message'],
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_cancel_agent',
      description: '取消自己的子代理；默认同时取消其整个子树。',
      parameters: {
        'type': 'object',
        'properties': {
          'agent_id': {'type': 'string'},
          'subtree': {'type': 'boolean'},
        },
        'required': ['agent_id'],
        'additionalProperties': false,
      },
    ),
  ];
  Future<String> callTool(
    String callerId,
    String name,
    Map<String, dynamic> args,
  ) async {
    final caller = _require(callerId);
    if (name == 'work_spawn_agent') {
      if (args.containsKey('read_only') && args['read_only'] is! bool ||
          args.containsKey('isolated') && args['isolated'] is! bool) {
        throw const FormatException('read_only/isolated 必须为布尔值');
      }
      final isolated = args['isolated'] == true;
      // An isolated worktree exists for writing, so it is writable unless the
      // caller explicitly asks for read-only (which is then a contradiction).
      final readOnly = args.containsKey('read_only')
          ? args['read_only'] != false
          : !isolated;
      return jsonEncode({
        'agent_id': spawn(
          parentId: callerId,
          task: args['task'] as String,
          model: args['model'] as String?,
          candidateId: args['candidate_id'] as String?,
          isolated: isolated,
          requireOwnership: true,
          ownedPaths: (args['owned_paths'] as List? ?? []).cast<String>(),
          readOnly: readOnly,
        ),
        'status': 'queued',
        'access': readOnly
            ? 'read_only'
            : isolated
            ? 'isolated_write'
            : 'shared_write',
        'access_note': readOnly
            ? '只读：可读取和调研，不能修改文件或运行命令。需要写入请另建 isolated=true 或 read_only=false 且带 owned_paths 的子代理。'
            : isolated
            ? '独立工作树：可写文件并运行命令；成果需由你核对后用 work_integrate_agent_file 整合。'
            : '共享工作区：只能写 owned_paths 中的文件，不能运行命令；测试请由你在主代理执行。',
        'capacity': capacity(callerId),
      });
    }
    bool descendant(WorkAgentRecord r) {
      var p = r.parentId;
      while (p != null) {
        if (p == callerId) return true;
        p = _records[p]?.parentId;
      }
      return false;
    }

    if (name == 'work_list_agents') {
      return jsonEncode({
        'capacity': capacity(callerId),
        'agents': _records.values
            .where((r) => r.id == callerId || descendant(r))
            .map((r) => r.toJson())
            .toList(),
      });
    }
    final target = _require(args['agent_id'] as String);
    if (!descendant(target) || target.conversationId != caller.conversationId) {
      throw StateError('只能管理自己的子代理');
    }
    if (name == 'work_followup_agent') {
      followup(target.id, args['message'] as String);
      return '已发送后续任务';
    }
    if (name == 'work_cancel_agent') {
      cancel(target.id, subtree: args['subtree'] != false);
      return '已取消';
    }
    throw StateError('未知代理工具：$name');
  }

  Future<String> safeCallTool(
    String callerId,
    String name,
    Map<String, dynamic> args,
  ) async {
    try {
      return await callTool(callerId, name, args);
    } on StateError catch (error) {
      return jsonEncode({
        'ok': false,
        'error': error.message,
        if (_records.containsKey(callerId)) 'capacity': capacity(callerId),
        'next_action': '不要重复超额或未授权请求。使用已有子代理追加任务、等待其结果，或由当前代理完成。',
      });
    } on FormatException catch (error) {
      return jsonEncode({'ok': false, 'error': error.message});
    } on TypeError {
      return jsonEncode({'ok': false, 'error': '代理工具参数类型不正确，请按工具定义重新填写。'});
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _streamNotifyTimer?.cancel();
    for (final r in _records.values) {
      r.token.cancel('运行时关闭');
    }
    for (final ready in _rootWaiters.values) {
      if (!ready.isCompleted) ready.completeError(StateError('运行时已关闭'));
    }
    _rootWaiters.clear();
    unawaited(_events.close());
    super.dispose();
  }
}

class _UnavailableAgentProvider implements LlmProvider {
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) => Stream.error(StateError('历史任务不能自动重放'));
}
