import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import '../../core/desktop_providers.dart';
import '../../data/models.dart';
import '../../domain/desktop/workspace_host.dart';
import '../../domain/desktop/workspace_tools.dart';
import '../../domain/llm/llm_provider.dart';
import '../../domain/workbench/changes/line_diff.dart';
import '../../state/chat_controller.dart';
import '../../state/conversation_model_choice.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../state/model_route_groups.dart';
import '../../state/model_service_credentials.dart';
import '../../state/session_policy.dart';
import '../../state/settings_controller.dart';
import '../../state/task_acceptance_provider.dart';
import '../../state/work_agents.dart';
import '../../state/work_approvals.dart';
import '../../state/work_changes.dart';
import '../../state/work_questions.dart';
import '../../state/work_rounds.dart';
import '../../state/work_task_steering.dart';
import '../../state/work_session_insights.dart';
import '../../state/research_terminal_controller.dart';
import '../../state/work_task_runtime.dart';
import '../shell/shell_tab.dart';
import '../library/resources_page.dart';
import 'protocol.dart';
import 'gui_navigation.dart';
import 'snapshot_evidence.dart';

class ControllerBridgeBackend implements BridgeBackend {
  ControllerBridgeBackend(this.container);
  final ProviderContainer container;
  Future<List<DesktopWorkspace>>? _workspaceCache;
  DateTime _workspaceRead = DateTime.fromMillisecondsSinceEpoch(0);
  final _profileSecrets = <String>{};
  final _availableProfiles = <String>{};
  DateTime _secretRead = DateTime.fromMillisecondsSinceEpoch(0);
  Object? _secretSettings;
  String _secretEpochSignature = '';
  Future<void>? _secretsPending;
  Future<String?>? _version;
  final _resuming = <String>{};
  final _gitCache =
      <String, ({DateTime time, Future<Map<String, Object?>> value})>{};
  ChatController get controller =>
      container.read(chatControllerProvider.notifier);
  ChatState get state =>
      container.read(chatControllerProvider).value ?? const ChatState();
  @override
  List<String> get capabilities => const [
    'session.list',
    'session.new',
    'message.send',
    'queue.add',
    'queue.remove',
    'task.stop',
    'task.resume',
    'approval.decide',
    'question.answer',
    'models.list',
    'model.set',
    'permission.set',
    'mode.set',
    'workspace.list',
    'workspace.prepare',
    'workspace.register',
    'workspace.set',
    'changes.list',
    'changes.diff',
    'task.accept',
    'task.revise',
    'agents.list',
    'agent.message',
    'agent.stop',
    'files.list',
    'gui.open',
  ];
  Conversation _session(String id) {
    final value = state.conversations.where((c) => c.id == id).firstOrNull;
    if (value == null) throw const BridgeFailure('not_found', '会话不存在');
    if (!value.workMode) {
      throw const BridgeFailure('unsupported', '请在 GUI 打开非工作会话');
    }
    return value;
  }

  void _idle(String id) {
    if (controller.isConversationRunning(id) || _resuming.contains(id)) {
      throw const BridgeFailure('busy', '任务运行中不能执行此操作');
    }
  }

  SessionPolicy _policy(String id) =>
      container.read(sessionPolicyProvider)[id] ?? const SessionPolicy();
  Future<List<DesktopWorkspace>> _workspaces() async {
    final host = container.read(desktopWorkspaceHostProvider);
    if (!host.supported) return [];
    if (_workspaceCache == null ||
        DateTime.now().difference(_workspaceRead).inSeconds >= 5) {
      _workspaceRead = DateTime.now();
      _workspaceCache = host.list().catchError((Object error) {
        _workspaceCache = null;
        throw error;
      });
    }
    return _workspaceCache!;
  }

  Map<String, Object?> _workspace(DesktopWorkspace w) => {
    'id': w.id,
    'name': w.name,
    'path': w.root,
    'access':
        w.scopes.where((s) => s.name == 'root').firstOrNull?.access.wireValue ??
        'deny',
    'remote': false,
  };
  List<Map<String, Object?>> _remoteWorkspaces() => [
    for (final profile in container.read(researchTerminalProvider).profiles)
      {
        'id': 'ssh:${profile.id}',
        'name': profile.name,
        'path': null,
        'access': null,
        'remote': true,
      },
  ];
  List<Map<String, Object?>> _models() {
    final settings = container.read(settingsControllerProvider).value;
    if (settings == null) return [];
    final result = <Map<String, Object?>>[];
    for (final profile in settings.profiles) {
      if (profile.authMode == 'apiKey' &&
          !_availableProfiles.contains(profile.id) &&
          !(profile.id == settings.activeProfileId &&
              settings.apiKey.isNotEmpty)) {
        continue;
      }
      for (final model in {
        ...profile.models,
        profile.chatModel,
        profile.reasonerModel,
      }.where((m) => m.isNotEmpty)) {
        final config = settings.config.copyWith(
          model: model,
          profileId: profile.id,
          baseUrl: profile.baseUrl,
          apiFormat: profile.apiFormat,
          authMode: profile.authMode,
        );
        final caps = config.capabilities;
        if (!caps.supportsTools) continue;
        result.add({
          'choice': modelSourceChoice(profile.id, model),
          'id': model,
          'source_id': profile.id,
          'source': profile.name,
          'efforts': reasoningEffortsFor(config).map((e) => e.wire).toList(),
          'thinking_supported':
              caps.supportsReasoningEffort ||
              caps.sendThinkingField ||
              caps.isReasoner,
        });
      }
    }
    for (final group in container.read(modelRouteGroupsProvider).groups) {
      final members = [
        for (final model in group.models)
          ...result.where((m) => m['id'] == model && m['source'] != '路由组'),
      ];
      if (members.isEmpty) continue;
      final efforts = (members.first['efforts'] as List).cast<String>().toSet();
      for (final member in members.skip(1)) {
        efforts.removeWhere((e) => !(member['efforts'] as List).contains(e));
      }
      result.add({
        'choice': '$modelGroupPrefix${group.id}',
        'id': group.name,
        'source_id': group.id,
        'source': '路由组',
        'efforts': efforts.toList(),
        'thinking_supported': members.every(
          (m) => m['thinking_supported'] == true,
        ),
      });
    }
    return result;
  }

  List<Map<String, Object?>> _agents(String id) => [
    for (final a
        in container
            .read(workAgentsProvider)
            .records
            .where((a) => a.conversationId == id))
      {
        'id': a.id,
        'parent_id': a.parentId,
        'name': a.role?.name ?? a.task,
        'model': a.model,
        'status': a.status.name,
        'activity': a.activity,
        'elapsed_ms': a.terminal
            ? null
            : DateTime.now().difference(a.createdAt).inMilliseconds,
        'output': a.output,
      },
  ];
  Map<String, Object?> _change(WorkFileChange change) {
    final lines = change.textSnapshot && change.beforeKnown
        ? buildLineDiff(change.before, change.after ?? '')
        : <DiffLine>[];
    return {
      'id': change.id,
      'path': change.path,
      'kind': change.deleted
          ? 'D'
          : change.isNew
          ? 'A'
          : 'M',
      'added': change.textSnapshot && change.beforeKnown
          ? lines.where((l) => l.kind == DiffLineKind.added).length
          : null,
      'removed': change.textSnapshot && change.beforeKnown
          ? lines.where((l) => l.kind == DiffLineKind.removed).length
          : null,
      'diff': !change.textSnapshot
          ? ['二进制文件：无文本差异']
          : !change.beforeKnown
          ? ['原始内容未知，无法生成准确差异']
          : [
              for (final line in lines)
                '${switch (line.kind) {
                  DiffLineKind.added => '+',
                  DiffLineKind.removed => '-',
                  _ => ' ',
                }}${line.text}',
            ],
      'summary': change.reverted ? '已恢复' : null,
      'round_id': change.roundId,
      'message_id': change.assistantId,
    };
  }

  List<Map<String, Object?>> _changes(String id) {
    final latest = _session(
      id,
    ).activePath.where((m) => m.role == MessageRole.assistant).lastOrNull?.id;
    return [
      for (final c
          in container
              .read(workChangesProvider)
              .where((c) => c.conversationId == id && c.assistantId == latest))
        _change(c),
    ];
  }

  String _status(Conversation c) {
    if (container
        .read(workApprovalsProvider)
        .any((a) => a.conversationId == c.id)) {
      return 'approval';
    }
    if (controller.isConversationRunning(c.id)) return 'running';
    final checkpoint = state.sessionCheckpoints[c.id];
    if (checkpoint?.status == SessionExecutionStatus.cancelled ||
        checkpoint?.status == SessionExecutionStatus.interrupted) {
      return 'stopped';
    }
    if (checkpoint?.status == SessionExecutionStatus.failed ||
        controller.errorForSession(c.id) != null) {
      return 'failed';
    }
    final acceptance = container.read(
      taskAcceptanceProvider,
    )[controller.taskSnapshotFor(c.id)?['rootId']];
    return switch (acceptance?.status) {
      TaskAcceptanceStatus.accepted => 'accepted',
      TaskAcceptanceStatus.waitingAcceptance => 'waiting_acceptance',
      TaskAcceptanceStatus.failed => 'failed',
      _ => 'idle',
    };
  }

  List<Map<String, Object?>> _sessions() => [
    for (final c in state.conversations.where((c) => c.workMode))
      {
        'id': c.id,
        'title': c.title,
        'status': _status(c),
        'workspace_id': _policy(c.id).sshProfileId.isNotEmpty
            ? 'ssh:${_policy(c.id).sshProfileId}'
            : container.read(conversationWorkspaceBindingsProvider)[c.id],
        'updated_at': c.updatedAt.toUtc().toIso8601String(),
      },
  ];

  @override
  Future<Map<String, Object?>> snapshot(String? session) async {
    await container.read(chatControllerProvider.future);
    if (session != null) {
      _session(session);
      await controller.loadSession(session);
    }
    await _refreshSecrets();
    final workspaces = await _workspaces();
    final binding = container.read(
      conversationWorkspaceBindingsProvider,
    )[session];
    final workspace = workspaces.where((w) => w.id == binding).firstOrNull;
    final git = workspace == null ? <String, Object?>{} : await _git(workspace);
    final version = await (_version ??= PackageInfo.fromPlatform()
        .then<String?>((info) => info.version)
        .catchError((Object _) => null));
    // A key may rotate while workspace or package metadata is loading.
    await _refreshSecrets();
    if (binding !=
        container.read(conversationWorkspaceBindingsProvider)[session]) {
      return snapshot(session);
    }
    // Capture public state only after all metadata awaits, so text/status refer
    // to one synchronous controller instant even if a stream changed meanwhile.
    final c = session == null ? null : _session(session);
    final core = session == null ? null : controller.taskSnapshotFor(session);
    final repository = core?['repositoryContext'] as Map?;
    final progress = container.read(workRoundsProvider)[session];
    final policy = session == null ? const SessionPolicy() : _policy(session);
    final remote = policy.sshProfileId.isNotEmpty;
    final remoteProfile = remote
        ? container
              .read(researchTerminalProvider)
              .profiles
              .where((p) => p.id == policy.sshProfileId)
              .firstOrNull
        : null;
    final workspaceLabel = remote
        ? 'SSH · ${remoteProfile?.name ?? '已移除的配置'}'
        : workspace?.name;
    final workspacePath = remote ? policy.remoteRoot : workspace?.root;
    final settings = container.read(settingsControllerProvider).value;
    final choice = container.read(conversationModelChoiceProvider)[session];
    final report = state.contextReports[session];
    final records =
        container
            .read(workTaskRuntimeProvider)
            .where((r) => r.conversationId == session)
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final runtime = records.firstOrNull;
    final path = c?.activePath ?? <ChatMessage>[];
    final evidence = TuiSnapshotEvidence(
      conversationId: session,
      messages: path,
      changes: container.read(workChangesProvider),
    );
    final data = <String, Object?>{
      'session': c == null
          ? null
          : {
              'id': c.id,
              'title': c.title,
              'status': _status(c),
              'phase': state.sessionCheckpoints[c.id]?.phase,
              'round': progress?.used,
              'round_limit': progress?.limit,
              'elapsed_ms': runtime == null
                  ? null
                  : (runtime.finishedAt ?? DateTime.now())
                        .difference(runtime.startedAt)
                        .inMilliseconds,
              'mode': policy.planOnly ? 'plan' : 'work',
              'permission': policy.approval.name,
              'model':
                  parseModelSourceChoice(choice ?? '')?.model ??
                  choice ??
                  settings?.model,
              'model_choice': choice,
              'thinking': controller.thinkingForSession(c.id),
              'request_count':
                  container
                      .read(workSessionInsightsProvider)[c.id]
                      ?.requests
                      .length ??
                  0,
              'effort': controller.effortForSession(c.id).wire,
              'workspace_id': remote ? 'ssh:${policy.sshProfileId}' : binding,
              'workspace_label': workspaceLabel,
              'workspace_path': workspacePath,
              'branch': remote ? null : git['branch'],
              'context_percent': report == null || report.inputBudgetTokens <= 0
                  ? null
                  : report.fraction * 100,
              'error': controller.errorForSession(c.id),
            },
      'startup': {
        'version': version,
        'workspace': workspaceLabel,
        'workspace_path': workspacePath,
        'branch': remote ? null : git['branch'],
        'dirty_count': remote ? null : git['dirty_count'],
        'contexts': [
          for (final source in repository?['sources'] as List? ?? [])
            if (source is Map && source['path'] is String)
              source['path'] as String,
        ],
        'issues': repository?['warnings'] ?? <Object?>[],
      },
      'messages': [
        for (final m in path)
          {
            'id': m.id,
            'role': m.role.name,
            'text': m.content,
            'thinking': m.reasoning,
            'attachments': [
              for (final a in m.attachments)
                {'name': a.name, 'mime': a.mimeType, 'size': a.sizeBytes},
            ],
          },
      ],
      'steps': [
        for (final m in path)
          for (final a in m.searchActivities)
            {
              'id': a.id,
              'message_id': m.id,
              'round_id': null,
              'verb': _verb(a.toolName),
              'object': a.query,
              'status':
                  a.status == SearchActivityStatus.running &&
                      _status(c!) == 'approval'
                  ? 'approval'
                  : a.status.name,
              'tail': const LineSplitter()
                  .convert(a.resultText ?? a.error ?? '')
                  .reversed
                  .take(a.status == SearchActivityStatus.failed ? 3 : 2)
                  .toList()
                  .reversed
                  .toList(),
              'elapsed_ms': a.startedAt == null
                  ? null
                  : (a.finishedAt ?? DateTime.now())
                        .difference(a.startedAt!)
                        .inMilliseconds,
              'exit_code': _exitCode(a.resultText),
              ...evidence.stepLineCounts(m.id, a),
              'detail': a.error,
            },
      ],
      'approvals': [
        for (final a
            in container
                .read(workApprovalsProvider)
                .where((a) => a.conversationId == session))
          {
            'id': a.id,
            'tool': a.tool,
            'arguments': a.arguments,
            'target': a.target,
            'reason': a.reason,
            'diff': evidence.approvalDiff(a),
          },
      ],
      'questions': [
        for (final q
            in container
                .read(workQuestionsProvider)
                .where((q) => q.conversationId == session))
          {
            'id': q.id,
            'questions': [
              for (final item in q.questions)
                {
                  'id': item.id,
                  'question': item.question,
                  'options': item.options,
                  'multiple': item.multiple,
                  'required': item.required,
                },
            ],
          },
      ],
      'changes': session == null ? [] : _changes(session),
      'agents': session == null ? [] : _agents(session),
      'queued': session == null
          ? []
          : container
                .read(workTaskSteeringProvider)
                .snapshot(session)
                .where((e) => e['status'] == 'queued')
                .toList(),
      'models': _models(),
      'workspaces': [...workspaces.map(_workspace), ..._remoteWorkspaces()],
      'sessions': _sessions(),
    };
    return _redact(data);
  }

  int? _exitCode(String? text) {
    try {
      final result = jsonDecode(text ?? '') as Map;
      return (result['exit_code'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  String _verb(String? name) => switch (name) {
    'coding_read_file' || 'coding_list_directory' => '读取',
    'coding_write_file' => '编辑',
    'coding_create_directory' => '新建',
    'work_run_command' => '运行',
    'web_search' => '搜索',
    'fetch_url' => '浏览',
    _ => '工具',
  };
  Map<String, Object?> _redact(Map<String, Object?> data) {
    final settings = container.read(settingsControllerProvider).value;
    final secrets = <String>[
      if (settings != null) settings.apiKey,
      if (settings != null) ...[
        settings.searchApiKey,
        settings.jevApiKey,
        settings.visionApiKey,
        settings.imageGenerationApiKey,
        settings.ttsApiKey,
        settings.asrApiKey,
        settings.gatewayToken,
        settings.gatewayLegacyToken,
        ...settings.customMcpTokens.values,
      ],
      ..._profileSecrets,
    ];
    return Map<String, Object?>.from(redactBridgeValue(data, secrets) as Map);
  }

  @override
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> params,
  ) async {
    await container.read(chatControllerProvider.future);
    await _refreshSecrets();
    if (!capabilities.contains(method)) {
      throw const BridgeFailure('unsupported', '不支持此操作');
    }
    if (method == 'session.list') {
      final sessions = _sessions();
      return {
        'sessions': params['workspace_id'] == null
            ? sessions
            : sessions
                  .where((s) => s['workspace_id'] == params['workspace_id'])
                  .toList(),
      };
    }
    if (method == 'models.list') return {'models': _models()};
    if (method == 'workspace.list') {
      return {
        'workspaces': [
          ...(await _workspaces()).map(_workspace),
          ..._remoteWorkspaces(),
        ],
      };
    }
    if (method == 'workspace.prepare' || method == 'workspace.register') {
      final rawPath = requiredString(params, 'path');
      if (!p.isAbsolute(rawPath)) {
        throw const BridgeFailure('invalid_params', '工作区路径必须为绝对路径');
      }
      final path = await Directory(rawPath).resolveSymbolicLinks();
      final existing = (await _workspaces())
          .where((w) => p.equals(p.normalize(w.root), p.normalize(path)))
          .firstOrNull;
      if (existing != null) return {'workspace': _workspace(existing)};
      if (method == 'workspace.prepare') {
        return {'confirmation_required': true, 'path': path};
      }
      if (params['confirmed'] != true) {
        throw const BridgeFailure('confirmation_required', '请确认工作区路径和权限');
      }
      final access = WorkspaceAccess.parse(requiredString(params, 'access'));
      if (access == WorkspaceAccess.deny) {
        throw const BridgeFailure('invalid_params', '请选择只读或读写权限');
      }
      final host = container.read(desktopWorkspaceHostProvider);
      final workspace = await host.add(
        id: const Uuid().v4(),
        name: p.basename(path),
        path: path,
        access: access,
      );
      _workspaceCache = null;
      return {'workspace': _workspace(workspace)};
    }
    if (method == 'session.new') {
      final workspaceId = params['workspace_id'] as String?;
      if (workspaceId != null &&
          !(await _workspaces()).any((w) => w.id == workspaceId)) {
        throw const BridgeFailure('not_found', '工作区不存在');
      }
      final id = await controller.createWorkSession(
        title: params['title'] as String?,
      );
      if (workspaceId != null) {
        await container
            .read(conversationWorkspaceBindingsProvider.notifier)
            .select(id, workspaceId);
      }
      return {'session_id': id};
    }
    if (method == 'gui.open') {
      final page = params['page'];
      if (page != null &&
          !['session', 'settings', 'library', 'media'].contains(page)) {
        throw const BridgeFailure('unsupported', '页面不存在');
      }
      final id = params['session_id'] as String?;
      final changeId = params['change_id'] as String?;
      final change = changeId == null
          ? null
          : container
                .read(workChangesProvider)
                .where((c) => c.id == changeId && c.conversationId == id)
                .firstOrNull;
      if (changeId != null && (id == null || change == null)) {
        throw const BridgeFailure('not_found', '改动不属于此会话或已不存在');
      }
      if (id != null) {
        _session(id);
        await controller.selectConversation(id);
      }
      container.read(shellTabProvider.notifier).set(switch (page) {
        'settings' => ShellTab.settings,
        'library' || 'media' => ShellTab.resources,
        _ => ShellTab.chat,
      });
      if (page == 'media') {
        container.read(resourceTabProvider.notifier).select('gen');
      }
      if (page == 'library') {
        container.read(resourceTabProvider.notifier).select('sets');
      }
      await const MethodChannel(
        'expert_chat/tui_bridge',
      ).invokeMethod<void>('show');
      if (change != null) {
        container.read(tuiGuiNavigationProvider.notifier).openChange(change);
      }
      return {'accepted': true};
    }
    final id = requiredString(params, 'session_id');
    _session(id);
    switch (method) {
      case 'message.send':
      case 'task.revise':
        _idle(id);
        await controller.loadSession(id);
        _idle(id);
        final text = requiredString(params, 'text');
        final attachments = _attachments(params['attachments']);
        unawaited(
          controller
              .sendToSession(id, text, attachments: attachments)
              .catchError((Object _) => false),
        );
      case 'queue.add':
        return {
          'id': await controller.addWorkRequirement(
            id,
            requiredString(params, 'text'),
          ),
        };
      case 'queue.remove':
        return {
          'text': await controller.withdrawWorkRequirement(
            id,
            requiredString(params, 'id'),
          ),
        };
      case 'task.stop':
        controller.stop(conversationId: id);
      case 'task.resume':
        final progress = container.read(workRoundsProvider)[id];
        if (progress?.paused == true) {
          container.read(workRoundsProvider.notifier).resume(id);
        } else {
          _idle(id);
          _resuming.add(id);
          unawaited(
            _resume(id)
                .catchError((Object _) {
                  controller.reportExternalFailure(
                    id,
                    '任务恢复失败，请在 GUI 核对原工作区、权限和任务记录。',
                  );
                })
                .whenComplete(() => _resuming.remove(id)),
          );
        }
      case 'approval.decide':
        container
            .read(workApprovalsProvider.notifier)
            .decideScoped(
              id,
              requiredString(params, 'id'),
              requiredString(params, 'decision'),
              reason: params['reason'] as String?,
            );
      case 'question.answer':
        final question = requiredString(params, 'id');
        if (!container
            .read(workQuestionsProvider)
            .any((q) => q.id == question && q.conversationId == id)) {
          throw const BridgeFailure('not_found', '问题不存在');
        }
        container
            .read(workQuestionsProvider.notifier)
            .answer(
              question,
              Map<String, dynamic>.from(params['answers'] as Map),
            );
      case 'permission.set':
        final permission = WorkApprovalMode.values
            .where((p) => p.name == params['permission'])
            .firstOrNull;
        if (permission == null) {
          throw const BridgeFailure('invalid_params', '无效权限');
        }
        if (permission == WorkApprovalMode.full &&
            params['confirmed'] != true) {
          throw const BridgeFailure('confirmation_required', '完全访问需要再次确认');
        }
        await container
            .read(sessionPolicyProvider.notifier)
            .save(id, _policy(id).copyWith(approval: permission));
      case 'mode.set':
        if (!['work', 'plan'].contains(params['mode'])) {
          throw const BridgeFailure('invalid_params', '无效模式');
        }
        await container
            .read(sessionPolicyProvider.notifier)
            .save(id, _policy(id).copyWith(planOnly: params['mode'] == 'plan'));
      case 'model.set':
        final choice = requiredString(params, 'choice');
        final model = _models().where((m) => m['choice'] == choice).firstOrNull;
        if (model == null) throw const BridgeFailure('not_found', '模型来源不存在');
        final effort = params['effort'] as String?;
        if (effort != null && !(model['efforts'] as List).contains(effort)) {
          throw const BridgeFailure('invalid_params', '此模型不支持该思考强度');
        }
        await container
            .read(conversationModelChoiceProvider.notifier)
            .select(id, choice);
        controller.configureSessionThinking(
          id,
          params['thinking'] == true,
          effort == null
              ? controller.effortForSession(id)
              : ReasoningEffort.fromWire(effort),
        );
      case 'workspace.set':
        _idle(id);
        final workspace = requiredString(params, 'workspace_id');
        if (workspace.startsWith('ssh:')) {
          final profile = workspace.substring(4);
          final research = container.read(researchTerminalProvider);
          if (!research.profiles.any((p) => p.id == profile)) {
            throw const BridgeFailure('not_found', 'SSH 配置不存在');
          }
          if (!research.isConnected || research.activeProfile?.id != profile) {
            throw const BridgeFailure('unsupported', '请先在 GUI 连接此 SSH 配置');
          }
          await container
              .read(sessionPolicyProvider.notifier)
              .save(id, _policy(id).copyWith(sshProfileId: profile));
          return {'accepted': true};
        }
        if (!(await _workspaces()).any((w) => w.id == workspace)) {
          throw const BridgeFailure('not_found', '工作区不存在');
        }
        _idle(id);
        container.read(workApprovalsProvider.notifier).revokeSession(id);
        await container
            .read(conversationWorkspaceBindingsProvider.notifier)
            .select(id, workspace);
        if (_policy(id).sshProfileId.isNotEmpty) {
          await container
              .read(sessionPolicyProvider.notifier)
              .save(id, _policy(id).copyWith(sshProfileId: ''));
        }
      case 'changes.list':
        return _redact({'changes': _changes(id)});
      case 'changes.diff':
        final changeId = requiredString(params, 'id');
        final change = _changes(
          id,
        ).where((c) => c['id'] == changeId).firstOrNull;
        if (change == null) throw const BridgeFailure('not_found', '改动不存在');
        return _redact({
          'id': changeId,
          'path': change['path'],
          'diff': change['diff'],
        });
      case 'task.accept':
        _idle(id);
        if (!await controller.verifyAndAcceptTask(id)) {
          throw const BridgeFailure('conflict', '验收未通过');
        }
      case 'agents.list':
        return _redact({'agents': _agents(id)});
      case 'agent.message':
      case 'agent.stop':
        final agent = requiredString(params, 'id');
        final runtime = container.read(workAgentsProvider);
        if (runtime.record(agent)?.conversationId != id) {
          throw const BridgeFailure('not_found', '子代理不存在');
        }
        if (method == 'agent.message') {
          runtime.followup(agent, requiredString(params, 'text'));
        } else {
          runtime.cancel(agent);
        }
      case 'files.list':
        return _redact(await _files(id, params['query'] as String? ?? ''));
      default:
        throw const BridgeFailure('unsupported', '不支持此操作');
    }
    return {'accepted': true};
  }

  Future<void> _resume(String id) async {
    final checkpoint = state.sessionCheckpoints[id];
    if (checkpoint?.resumeRequired == true) {
      if (!await controller.resumeSessionTask(id) &&
          controller.errorForSession(id) == null) {
        controller.reportExternalFailure(id, '原任务未能恢复，请核对原工作区和验收条件后重试。');
      }
    } else {
      await controller.sendToSession(id, '继续完成任务。先检查当前状态与已有结果，避免重复副作用。');
    }
  }

  Future<void> _refreshSecrets() async {
    while (true) {
      if (_secretsPending case final pending?) {
        await pending;
        continue;
      }
      final settings = container.read(settingsControllerProvider).value;
      final epochs = jsonEncode(
        container.read(explicitCredentialEpochProvider),
      );
      if (identical(settings, _secretSettings) &&
          epochs == _secretEpochSignature &&
          DateTime.now().difference(_secretRead).inSeconds < 5) {
        return;
      }
      final reading = (() async {
        _availableProfiles.clear();
        if (settings == null) return;
        for (final profile in settings.profiles) {
          try {
            final credentials = await container
                .read(settingsControllerProvider.notifier)
                .readCurrentProfileCredentials(profile.id);
            if (credentials.apiKey.isNotEmpty) {
              _profileSecrets.add(credentials.apiKey);
              _availableProfiles.add(profile.id);
            }
          } catch (_) {
            /* An unavailable credential is never serialized. */
          }
        }
      })();
      _secretsPending = reading;
      try {
        await reading;
        _secretSettings = settings;
        _secretEpochSignature = epochs;
        _secretRead = DateTime.now();
      } finally {
        _secretsPending = null;
      }
      // Recheck after I/O: callers waiting for an older refresh must also see
      // rotations that happened while that refresh was in flight.
    }
  }

  Future<Map<String, Object?>> _git(DesktopWorkspace workspace) {
    final existing = _gitCache[workspace.id];
    if (existing != null &&
        DateTime.now().difference(existing.time).inSeconds < 10) {
      return existing.value;
    }
    final operation = (() async {
      if (!workspace.scopes.any(
        (s) => s.name == 'root' && s.access != WorkspaceAccess.deny,
      )) {
        return <String, Object?>{};
      }
      try {
        final root = await Directory(workspace.root).resolveSymbolicLinks();
        final gitDirectory = Directory(p.join(root, '.git'));
        if (!await gitDirectory.exists() ||
            !p.isWithin(root, await gitDirectory.resolveSymbolicLinks())) {
          return <String, Object?>{};
        }
        final location = [
          '--git-dir=${gitDirectory.path}',
          '--work-tree=$root',
        ];
        final branch = await Process.run(
          'git',
          [...location, 'symbolic-ref', '--short', 'HEAD'],
          environment: {'GIT_OPTIONAL_LOCKS': '0'},
        ).timeout(const Duration(seconds: 2));
        final status = await Process.run(
          'git',
          [
            '--no-optional-locks',
            '-c',
            'core.fsmonitor=false',
            '-c',
            'core.untrackedCache=false',
            ...location,
            'status',
            '--porcelain=v1',
            '-z',
            '--untracked-files=normal',
          ],
          environment: {'GIT_OPTIONAL_LOCKS': '0'},
        ).timeout(const Duration(seconds: 2));
        if (status.exitCode != 0) return <String, Object?>{};
        final records = (status.stdout as String).split('\u0000');
        var count = 0;
        for (var i = 0; i < records.length; i++) {
          if (records[i].isEmpty) continue;
          count++;
          if (records[i].startsWith('R') ||
              records[i].startsWith('C') ||
              records[i].startsWith(' R') ||
              records[i].startsWith(' C')) {
            i++;
          }
        }
        return <String, Object?>{
          'branch': branch.exitCode == 0
              ? (branch.stdout as String).trim()
              : null,
          'dirty_count': count,
        };
      } catch (_) {
        return <String, Object?>{};
      }
    })();
    _gitCache[workspace.id] = (time: DateTime.now(), value: operation);
    return operation;
  }

  Future<Map<String, Object?>> _files(String id, String query) async {
    final normalized = query.replaceAll(r'\', '/');
    if (normalized.startsWith('/') ||
        normalized.contains(':') ||
        normalized.split('/').contains('..')) {
      throw const BridgeFailure('invalid_params', '只允许工作区内的相对路径');
    }
    final slash = normalized.lastIndexOf('/');
    final directory = slash < 0 ? '.' : normalized.substring(0, slash);
    final prefix = slash < 0 ? '' : normalized.substring(0, slash + 1);
    final filter = normalized.substring(slash + 1).toLowerCase();
    final binding = container.read(conversationWorkspaceBindingsProvider)[id];
    if (binding == null || _policy(id).sshProfileId.isNotEmpty) {
      throw const BridgeFailure('unsupported', '请先选择本机已授权工作区');
    }
    final token = CancelToken();
    final session = await WorkspaceToolSession.open(
      container.read(desktopWorkspaceHostProvider),
      binding,
      token,
    );
    try {
      final result = jsonDecode(
        await session.call('coding_list_directory', {
          'path': directory.isEmpty ? '.' : directory,
          'scope': 'root',
        }, token),
      );
      final values = result is Map
          ? (result['entries'] ?? result['files'])
          : null;
      if (values is! List) {
        throw const BridgeFailure('unsupported', '工具未返回文件列表');
      }
      return {
        'files': [
          for (final item in values)
            if (item is Map &&
                '${item['name'] ?? item['path']}'.toLowerCase().contains(
                  filter,
                ))
              {
                'path': '$prefix${item['name'] ?? item['path']}',
                'kind': item['kind'] ?? item['type'] ?? 'file',
              },
        ],
      };
    } finally {
      await session.close();
    }
  }

  List<Attachment> _attachments(Object? raw) {
    if (raw == null) return [];
    if (raw is! List || raw.length > 8) {
      throw const BridgeFailure('invalid_params', '最多 8 个附件');
    }
    return [
      for (final item in raw)
        (() {
          if (item is! Map) {
            throw const BridgeFailure('invalid_params', '附件格式无效');
          }
          final mime = item['mime'];
          if (![
            'image/png',
            'image/jpeg',
            'image/webp',
            'text/plain',
            'text/markdown',
          ].contains(mime)) {
            throw const BridgeFailure('invalid_params', '不支持的附件类型');
          }
          final bytes = base64Decode(item['data_base64'] as String);
          if (bytes.length > 700 * 1024) {
            throw const BridgeFailure('too_large', '附件过大');
          }
          return Attachment(
            name: item['name'] as String,
            mimeType: mime as String,
            sizeBytes: bytes.length,
            imageBase64: mime.startsWith('image/') ? base64Encode(bytes) : null,
            text: mime.startsWith('text/') ? utf8.decode(bytes) : '',
          );
        })(),
    ];
  }
}
