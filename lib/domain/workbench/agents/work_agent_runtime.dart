import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../data/models.dart';
import '../../../data/subagent_role.dart';
import 'agent_instructions.dart';
import '../../context/context_window_manager.dart';
import '../../chat/tool_markup_filter.dart';
import '../../llm/llm_provider.dart';

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
  });
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
  });
  final String id, conversationId, taskId, task;
  final String? parentId;
  final int depth;
  final bool external;
  final WorkAgentLimits limits;
  WorkAgentEnvironment environment;
  final DateTime createdAt = DateTime.now();
  WorkAgentStatus status = WorkAgentStatus.queued;
  String model = 'Auto', output = '', activity = '排队中';
  final List<String> logs = [], files = [];
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
  CancelToken token = CancelToken();
  LlmConfig? resolvedConfig;
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
  final Map<String, WorkAgentRecord> _records = {};
  final Queue<String> _queue = Queue();
  final Set<String> _running = {};
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
                'task': {'type': 'string'},
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
  Future<void> acquireRootSlot(String rootId, CancelToken token) async {
    final root = _require(rootId);
    if (!root.external || root.restored) throw StateError('不是当前根任务');
    if (token.isCancelled) throw token.cancelError!;
    if (_rootActive.contains(rootId)) return;
    final existing = _rootWaiters[rootId];
    if (existing != null) return existing.future;
    final ready = Completer<void>();
    _rootWaiters[rootId] = ready;
    root.status = WorkAgentStatus.queued;
    root.activity = '等待本任务模型执行名额';
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
    if (r != null && !r.terminal) {
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

  String spawn({
    required String parentId,
    required String task,
    String? model,
  }) {
    final parent = _require(parentId);
    if (parent.restored) throw StateError('历史代理已中断，请在新回合创建任务');
    if (parent.status == WorkAgentStatus.cancelled) throw StateError('父任务已取消');
    if (task.trim().isEmpty) throw const FormatException('子任务不能为空');
    if (parent.depth >= parent.limits.maxDepth)
      throw StateError('已达到最大递归深度 ${parent.limits.maxDepth}（根为 0）');
    if (parent.childrenCreated >= parent.limits.maxChildren)
      throw StateError('已达到直属子任务累计上限 ${parent.limits.maxChildren}');
    final requestedModel = model?.trim() ?? '';
    if (parent.environment.selectRole != null &&
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
    if (pool.isEmpty) throw StateError('子代理模型池为空，请用户在子代理设置中加入模型');
    if (requestedModel.isNotEmpty &&
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
    if (r.status == WorkAgentStatus.cancelled ||
        (r.terminal && !_childrenActive(id)))
      return;
    r.status = WorkAgentStatus.cancelled;
    r.activity = '已取消';
    r.token.cancel('代理已取消');
    if (r.external) r.environment.onCancelRoot?.call();
    _rootActive.remove(id);
    final waiting = _rootWaiters.remove(id);
    if (waiting != null && !waiting.isCompleted)
      waiting.completeError(StateError('根任务已取消'));
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
          'output': r.output.length > 8000
              ? r.output.substring(r.output.length - 8000)
              : r.output,
          'logs': r.logs.reversed
              .take(12)
              .map(
                (line) => line.length > 2000 ? line.substring(0, 2000) : line,
              )
              .toList()
              .reversed
              .toList(),
        },
      )
      .toList();

  void restoreJournal(List<Map<String, dynamic>> rows) {
    for (final j in rows.reversed) {
      try {
        final saved = WorkAgentStatus.values.byName(j['status'] as String);
        final interrupted =
            saved == WorkAgentStatus.running ||
            saved == WorkAgentStatus.queued ||
            saved == WorkAgentStatus.waiting;
        final r =
            WorkAgentRecord(
                id: j['id'] as String,
                conversationId: j['conversationId'] as String,
                taskId: j['taskId'] as String,
                task: j['task'] as String,
                depth: (j['depth'] as num).toInt(),
                parentId: j['parent_id'] as String?,
                external: j['external'] == true,
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
              ..restored = true
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
        r.cost = (j['cost'] as num?)?.toDouble();
        if (j['role_id'] is String)
          r.role = SubagentRole(
            id: j['role_id'] as String,
            name: j['role_name'] as String? ?? '',
            when: '',
            instructions: '',
          );
        r.roleReason = j['role_reason'] as String? ?? '';
        r.currency = j['currency'] as String?;
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
    r.logs.add(text.length > 12000 ? text.substring(0, 12000) : text);
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
          _running.contains(id))
        continue;
      if (_runningForRoot(_rootId(r)) >= r.limits.maxConcurrent.clamp(1, 16)) {
        _queue.addLast(id);
        continue;
      }
      if (r.external) {
        final ready = _rootWaiters.remove(id);
        if (ready == null || ready.isCompleted) continue;
        _rootActive.add(id);
        r.status = WorkAgentStatus.running;
        r.activity = '主模型执行中';
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

  int _runningForRoot(String rootId) => [..._running, ..._rootActive]
      .where((id) => _records[id] != null && _rootId(_records[id]!) == rootId)
      .length;

  Future<void> _run(WorkAgentRecord r) async {
    Stopwatch? requestElapsed;
    r.status = WorkAgentStatus.running;
    r.activity = '选择模型';
    _notify();
    try {
      if (r.role == null && r.environment.selectRole != null) {
        r.activity = '按任务分配角色';
        _notify();
        final assignment = await r.environment.selectRole!(
          r.task,
          r.model == 'Auto' ? null : r.model,
          r.token,
        );
        if (r.token.isCancelled) return;
        if (!r.environment.allowedModels.any(
          (m) => m.model == assignment.model,
        ))
          throw StateError('角色分配返回池外模型');
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
        while (r.mailbox.isNotEmpty) {
          r.context.add(
            LlmRequestMessage(
              role: MessageRole.user,
              content: r.mailbox.removeFirst(),
            ),
          );
        }
        r.rounds++;
        if (r.role != null)
          AgentInstructions.replace(
            r.context,
            r.role!.instructions,
            subagent: true,
          );
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
        await for (final chunk in r.environment.provider.streamChat(
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
              : [
                  ...r.environment.tools.where(
                    (t) => !toolNames.contains(t.name),
                  ),
                  ...toolsFor(r.id),
                ],
          thinking: r.environment.thinking,
          reasoningEffort: r.environment.reasoningEffort,
          cancelToken: r.token,
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
            config = chunk.actualConfig!.copyWith(reasoningGuardEnabled: false);
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
          if (chunk.responseOutputItems != null)
            native = chunk.responseOutputItems!;
          for (final call in chunk.toolCalls ?? <ToolCall>[]) {
            (calls[call.index] ??= ToolCallDraft(call.index)).merge(call);
          }
          // Usage chunks describe cumulative request counters, not deltas.
          requestUsage = chunk.usage ?? requestUsage;
          if (text.isNotEmpty) r.output = text.toString();
          _notifyStreamSoon();
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
          _report(r);
          _notify();
          return;
        }
        for (final call in complete) {
          if (r.token.isCancelled) return;
          r.activity = '工具 · ${call.name}';
          _log(r, '${call.name} ${call.argumentsJson}');
          _notify();
          String result;
          try {
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
            if (call.name == 'coding_write_file' && args['path'] is String) {
              // A refusal is also a result. Count only a real write receipt.
              try {
                final receipt = jsonDecode(result);
                if (receipt is Map &&
                    receipt['path'] == args['path'] &&
                    receipt['sha256'] is String &&
                    (receipt['sha256'] as String).isNotEmpty &&
                    !r.files.contains(args['path']))
                  r.files.add(args['path'] as String);
              } catch (_) {}
            }
          } catch (error) {
            result = '工具执行失败：$error';
          }
          _log(r, result);
          r.context.add(
            LlmRequestMessage(
              role: MessageRole.tool,
              content: result.length > 24000
                  ? '${result.substring(0, 24000)}\n[输出已截断]'
                  : result,
              toolCallId: call.id,
            ),
          );
        }
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
    final content =
        '子代理 ${r.id}（${r.role?.name ?? '通用执行'}，${r.status.name}，${r.model}）\n任务：${r.task}\n${r.output}\n文件：${r.files.join(', ')}';
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
    if (!_disposed)
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
          '创建独立后台子代理并立即返回 ID。角色分配模型根据任务选择角色并应用其系统指令；角色绑定模型优先，model 只作为自动选模型时的建议且限用户模型池。子代理可递归分工，完成后自动汇报。继承工作区和权限，不能扩大授权。',
      parameters: {
        'type': 'object',
        'properties': {
          'task': {'type': 'string'},
          'model': {'type': 'string'},
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
    if (name == 'work_spawn_agent')
      return jsonEncode({
        'agent_id': spawn(
          parentId: callerId,
          task: args['task'] as String,
          model: args['model'] as String?,
        ),
        'status': 'queued',
        'capacity': capacity(callerId),
      });
    bool descendant(WorkAgentRecord r) {
      var p = r.parentId;
      while (p != null) {
        if (p == callerId) return true;
        p = _records[p]?.parentId;
      }
      return false;
    }

    if (name == 'work_list_agents')
      return jsonEncode({
        'capacity': capacity(callerId),
        'agents': _records.values
            .where((r) => r.id == callerId || descendant(r))
            .map((r) => r.toJson())
            .toList(),
      });
    final target = _require(args['agent_id'] as String);
    if (!descendant(target) || target.conversationId != caller.conversationId)
      throw StateError('只能管理自己的子代理');
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
