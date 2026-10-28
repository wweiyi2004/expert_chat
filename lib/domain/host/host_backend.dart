import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
// Both endpoints ship Drift 2.33.0; compatibility is checked by transport tests.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as p;
import '../../core/providers.dart';
import '../../core/desktop_providers.dart';
import '../../features/tui_bridge/backend.dart';
import '../../features/tui_bridge/protocol.dart';
import '../../features/tui_bridge/server.dart';
import '../../state/chat_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/work_agents.dart';
import '../../state/work_processes.dart';
import '../../state/work_approvals.dart';
import '../../state/work_questions.dart';
import '../../state/work_rounds.dart';
import '../../state/work_changes.dart';
import '../../state/work_task_runtime.dart';
import '../../state/work_runtime_logs.dart';
import '../../state/task_acceptance_provider.dart';
import '../../state/task_plans.dart';
import '../../state/session_policy.dart';
import '../../state/conversation_model_choice.dart';
import '../../state/conversation_workspace_bindings.dart';
import '../../state/work_session_insights.dart';
import '../../state/work_memory.dart';
import '../../state/role_evolution.dart';
import '../../state/model_service_routing.dart';
import '../../state/model_route_groups.dart';
import '../../state/tool_registry_settings.dart';
import '../../state/supervisor_settings.dart';
import '../../state/role_validation_settings.dart';
import '../../state/work_task_steering.dart';
import 'wire_models.dart';
import 'settings_api.dart';
import 'chat_api.dart';
import 'runtime_api.dart';
import 'llm_service.dart';
import 'llm_wire.dart';
import 'chat_projection.dart';
import 'operation_ledger.dart';
import 'research_service.dart';
import 'research_wire.dart';
import 'database_hub.dart';
import '../../data/full_backup_service.dart';
import '../../data/backup_journal.dart';
import '../../data/backup_codec.dart';
import '../../platform/atomic_file.dart';
import '../../platform/paths_host.dart' show HostPaths;
import '../../state/research_terminal_controller.dart';

class DesktopHostBackend extends ControllerBridgeBackend
    implements
        PersistentBridgeHost,
        PrivilegedBridgeBackend,
        BridgeDatabaseEndpoint,
        BridgeGuiLifecycle {
  DesktopHostBackend(
    super.container, {
    required this.requestShutdown,
    required this.databaseServer,
    required this.operationLedger,
    this.guiEnvironment = const {},
  }) {
    controller.reportHostVisibleSessions({});
    for (final provider in <ProviderListenable<dynamic>>[
      chatControllerProvider,
      workApprovalsProvider,
      workQuestionsProvider,
      workRoundsProvider,
      workChangesProvider,
      workTaskRuntimeProvider,
      taskAcceptanceProvider,
      taskPlansProvider,
      researchTerminalProvider,
      sessionPolicyProvider,
      conversationModelChoiceProvider,
      conversationWorkspaceBindingsProvider,
      workSessionInsightsProvider,
      workRuntimeLogsProvider,
      workAgentModelPoolProvider,
      roleEvolutionProvider,
      modelUsageControllerProvider,
    ]) {
      _subscriptions.add(
        container.listen(provider, (_, _) {
          _revision++;
        }),
      );
    }
    _subscriptions.add(
      container.listen(settingsControllerProvider, (_, _) {
        _revision++;
        _settingsRevision++;
      }),
    );
    void changed() {
      _revision++;
    }

    final agents = container.read(workAgentsProvider),
        processes = container.read(workProcessesProvider),
        hooks = container.read(workHooksProvider);
    agents.addListener(changed);
    processes.addListener(changed);
    hooks.addListener(changed);
    _removeListeners = () {
      agents.removeListener(changed);
      processes.removeListener(changed);
      hooks.removeListener(changed);
    };
    container
        .read(researchTerminalProvider.notifier)
        .setHostKeyHandlers(
          onTrust: (info) async =>
              await _requestGui({
                'kind': 'sshHostKey',
                'fingerprint': info.fingerprintSha256,
                'keyType': info.keyType,
              }) ==
              true,
          onMismatch: (info, previous) async =>
              await _requestGui({
                'kind': 'sshHostKey',
                'fingerprint': info.fingerprintSha256,
                'keyType': info.keyType,
                'previous': previous,
              }) ==
              true,
        );
  }
  final Future<void> Function() requestShutdown;
  final DriftServer databaseServer;
  final HostOperationLedger operationLedger;
  final Map<String, String> guiEnvironment;
  late final databaseHub = HostDatabaseHub(databaseServer);
  final _subscriptions = <ProviderSubscription<dynamic>>[];
  void Function()? _removeListeners;
  int _revision = 0, _settingsRevision = 0;
  bool _shutdownRequested = false;
  bool _maintenance = false;
  final _jobs = <String, Map<String, Object?>>{};
  late final _llm = HostLlmService(() => container.read(llmProvider));
  late final _research = HostResearchService(container);
  final _guiScopes = <String>{};
  final _guiSelections = <String, int>{};
  final _chatProjections = <String, HostChatProjection>{};
  final _projectionCache = <String, ({Object? source, Object? value})>{};
  final _wireRuntime =
      <String, ({Object? value, String encoded, int version})>{};
  int _nextProjectionVersion = 0;
  T _cached<T>(String key, Object? source, T Function() encode) {
    final cached = _projectionCache[key];
    if (cached != null && identical(cached.source, source)) {
      return cached.value as T;
    }
    final value = encode();
    _projectionCache[key] = (source: source, value: value);
    return value;
  }

  final _guiActions =
      <
        String,
        ({
          String scope,
          Map<String, Object?> request,
          Completer<Object?> result,
        })
      >{};
  static final _guiScopeKey = Object();
  @override
  void registerGuiClient(String scope) {
    _guiScopes.add(scope);
    _revision++;
  }

  @override
  Future<void> releaseClient(String scope) async {
    cancelWindowScope(scope);
    _llm.disconnect(scope);
    await _research.releaseClient(scope);
    _guiScopes.remove(scope);
    _guiSelections.remove(scope);
    _chatProjections.remove(scope);
    for (final entry
        in _guiActions.entries.where((e) => e.value.scope == scope).toList()) {
      _guiActions.remove(entry.key);
      if (!entry.value.result.isCompleted) {
        entry.value.result.completeError(StateError('图形客户端已断开'));
      }
    }
    await super.releaseClient(scope);
    _revision++;
  }

  Future<Object?> _requestGui(
    Map<String, Object?> request, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    var scope = Zone.current[_guiScopeKey] as String?;
    scope = scope != null && _guiScopes.contains(scope)
        ? scope
        : _guiScopes.firstOrNull;
    if (scope == null) {
      final program = p.join(HostPaths.bundleDirectory, 'expert_chat.exe');
      if (!await File(program).exists()) {
        throw const BridgeFailure('gui_unavailable', '此安装未包含图形客户端；终端任务仍可独立执行');
      }
      await Process.start(
        program,
        [],
        mode: ProcessStartMode.detached,
        environment: guiEnvironment,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (_guiScopes.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      scope = _guiScopes.firstOrNull;
    }
    if (scope == null) {
      throw const BridgeFailure('gui_unavailable', '图形客户端未连接，未修改当前任务');
    }
    final id = const Uuid().v4(), result = Completer<Object?>();
    _guiActions[id] = (
      scope: scope,
      request: {'id': id, ...request},
      result: result,
    );
    _revision++;
    try {
      return await result.future.timeout(timeout);
    } finally {
      _guiActions.remove(id);
      _revision++;
    }
  }

  Future<void> navigateGui(Map<String, Object?> request) async {
    await _requestGui({'kind': 'navigate', ...request});
  }

  Future<String> authorizeInGui(
    String url,
    String scheme,
    Map<String, Object?> options,
  ) async =>
      await _requestGui({
            'kind': 'authorize',
            'url': url,
            'scheme': scheme,
            'options': options,
          }, timeout: const Duration(minutes: 5))
          as String;
  HostSettingsApi get _settings => HostSettingsApi(
    container.read(settingsControllerProvider.notifier),
    revision: () => revision,
  );
  HostChatApi get _chat => HostChatApi(controller, () => state);
  late final _runtime = HostRuntimeApi(container);
  late final _workspace = HostWorkspaceApi(
    container.read(desktopWorkspaceHostProvider),
  );
  bool get idle =>
      !hasTerminalSchedules &&
      !hasWorkbenchJobs &&
      !hasActiveShell &&
      controller.runningConversationIds.isEmpty &&
      !_maintenance &&
      !_llm.hasActive &&
      !_research.hasActiveTransfers &&
      !container.read(researchTerminalProvider).isConnected &&
      !container.read(researchTerminalProvider).analyzing &&
      !container.read(workAgentsProvider).records.any((r) => !r.terminal) &&
      !container.read(workProcessesProvider).records.any((r) => r.active) &&
      !container
          .read(workHooksProvider)
          .records
          .any(
            (r) =>
                container
                    .read(workHooksProvider)
                    .boundRoot(r.definition.conversationId) !=
                null,
          ) &&
      !_jobs.values.any((r) => r['done'] != true) &&
      !state.conversations.any(
        (c) => c.messages.any((m) => m.longTask?.isActive == true),
      );
  Future<void> drain() async {
    _shutdownRequested = true;
    _llm.close();
    final hooks = container.read(workHooksProvider);
    for (final c in state.conversations) {
      hooks.unbind(c.id);
    }
    final agents = container.read(workAgentsProvider),
        processes = container.read(workProcessesProvider);
    for (final a in agents.records.where((a) => !a.terminal).toList()) {
      agents.cancel(a.id);
    }
    for (final process in processes.records.where((p) => p.active).toList()) {
      processes.stop(process.id);
    }
    await Future.wait([
      for (final id in controller.runningConversationIds)
        controller
            .stopAndWait(conversationId: id)
            .timeout(const Duration(seconds: 15), onTimeout: () {}),
    ]);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((_jobs.values.any((j) => j['done'] != true) ||
            processes.records.any((r) => r.active)) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await controller.flushHostState();
    await container.read(workChangesProvider.notifier).flush();
    await container.read(taskPlansProvider.notifier).flush();
    await container.read(workTaskRuntimeProvider.notifier).flush();
    await container.read(workRuntimeLogsProvider.notifier).flush();
    await agents.flushJournal();
    await container
        .read(sharedPrefsProvider)
        .setString('workProcessJournal.v1', jsonEncode(processes.journal()));
    await container.read(researchTerminalProvider.notifier).disconnect();
  }

  @override
  int get revision => _revision;
  @override
  String get hostVersion => '1';
  @override
  bool isPrivilegedMethod(String method) =>
      const {
        'chat.call',
        'settings.call',
        'runtime.call',
        'workspace.call',
      }.contains(method) ||
      method.startsWith('host.') &&
          !const {'host.info', 'host.shutdown'}.contains(method);
  @override
  Future<void> attachDatabase(WebSocket socket) => databaseHub.attach(socket);
  @override
  List<String> get capabilities => [
    ...super.capabilities,
    'host.info',
    'host.shutdown',
  ];

  @override
  Future<Map<String, Object?>> invoke(
    String method,
    Map<String, dynamic> params,
  ) => runForWindow(
    params['_bridge_client_scope'] as String?,
    () => _invokeWithLedger(method, params),
  );

  Future<Map<String, Object?>> _invokeWithLedger(
    String method,
    Map<String, dynamic> params,
  ) async {
    const reads = {
      'provider.login.list',
      'provider.login.account',
      'provider.login.usage',
      'provider.login.status',
      'terminal.query',
      'host.info',
      'host.gui.snapshot',
      'host.loadSession',
      'host.operation',
      'host.gui.actionResult',
      'host.preferences.read',
      'host.credentials.read',
      'host.credentials.readAll',
      'host.library.read',
      'host.library.root',
      'host.memory.read',
      'host.memory.location',
      'settings.get',
      'session.list',
      'models.list',
      'workspace.list',
      'changes.list',
      'changes.diff',
      'agents.list',
      'files.list',
      'plan.get',
      'checkpoint.list',
      'checkpoint.preview',
      'host.ssh.poll',
      'host.ssh.cancel',
      'host.ssh.resize',
    };
    if (reads.contains(method) ||
        method == 'host.llm.poll' ||
        method == 'host.llm.cancel') {
      return _invokeHost(method, params);
    }
    final request =
        params['_bridge_request_id'] as String? ?? const Uuid().v4();
    return operationLedger.execute(
      request,
      method,
      params,
      () => _invokeHost(method, params),
    );
  }

  Future<Map<String, Object?>> _invokeHost(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_shutdownRequested && method != 'host.info') {
      throw const BridgeFailure('closing', '宿主正在退出，未接受新操作');
    }
    if (_maintenance &&
        !(method == 'terminal.query' && params['topic'] == 'wb.job') &&
        !const {
          'host.info',
          'host.operation',
          'host.gui.snapshot',
          'host.gui.actionResult',
          'host.llm.poll',
          'host.llm.cancel',
          'host.ssh.poll',
          'host.ssh.cancel',
          'settings.get',
          'session.list',
          'plan.get',
        }.contains(method)) {
      throw const BridgeFailure('maintenance', '宿主正在维护数据，此操作未接受');
    }
    if (method == 'host.info') {
      return {
        'engine': 'dart',
        'pid': pid,
        'protocol': 1,
        'schema_version': 17,
        'gui_required': false,
        'host_version': hostVersion,
      };
    }
    if (method == 'host.ssh.poll') {
      return _research.poll(
        params,
        requiredString(params, '_bridge_client_scope'),
      );
    }
    if (method == 'host.ssh.cancel') {
      _research.cancel(
        requiredString(params, 'id'),
        requiredString(params, '_bridge_client_scope'),
      );
      return {'accepted': true};
    }
    if (method == 'host.ssh.control') {
      final operation = requiredString(params, 'operation');
      if (!const {
        'input',
        'ctrlLatch',
        'clearInterrupt',
        'clearProposal',
        'editProposal',
        'executeApproved',
        'terminal.write',
      }.contains(operation)) {
        throw const BridgeFailure('unsupported', '未知终端控制操作');
      }
      final value = await _research.invoke(
        operation,
        wireMap(params['arguments']),
        requiredString(params, '_bridge_client_scope'),
      );
      _revision++;
      return {'value': encodeHostValue(value)};
    }
    if (method == 'host.ssh.resize') {
      await _research.invoke(
        params['kind'] == 'terminal' ? 'terminal.resize' : 'resize',
        params,
        requiredString(params, '_bridge_client_scope'),
      );
      return {'accepted': true};
    }
    if (method.startsWith('host.llm.')) return _llm.invoke(method, params);
    if (method == 'host.gui.snapshot') return _guiSnapshot(params);
    if (method == 'host.gui.actionResult') {
      final id = requiredString(params, 'id'), action = _guiActions[id];
      if (action == null) return {'accepted': true, 'already_finished': true};
      if (action.scope != params['_bridge_client_scope']) {
        throw const BridgeFailure('forbidden', '界面动作不属于此连接');
      }
      if (!action.result.isCompleted) {
        if (params['error'] != null) {
          action.result.completeError(StateError('图形操作取消或失败'));
        } else {
          action.result.complete(params['result']);
        }
      }
      return {'accepted': true};
    }
    if (method == 'host.loadSession') {
      final id = requiredString(params, 'session_id');
      final scope = params['_bridge_client_scope'] as String?;
      final selection = params['selection_revision'] as int? ?? 0;
      if (scope != null && params['view'] != false) {
        if (selection < (_guiSelections[scope] ?? -1)) {
          return {'superseded': true};
        }
        _guiSelections[scope] = selection;
      }
      if (!state.conversations.any((c) => c.id == id)) {
        throw const BridgeFailure('not_found', '会话已不存在');
      }
      await controller.loadSession(id);
      if (params['view'] != false &&
          scope != null &&
          _guiSelections[scope] == selection) {
        await selectClientSession(scope, id);
      }
      return {'accepted': true};
    }
    if (method == 'host.operation') {
      final job = _jobs[requiredString(params, 'job_id')];
      if (job == null) {
        throw const BridgeFailure('unknown_result', '操作回执不在当前宿主中；请核对结果，不要自动重发');
      }
      return Map<String, Object?>.from(job);
    }
    if (const {
      'chat.call',
      'settings.call',
      'runtime.call',
      'workspace.call',
    }.contains(method)) {
      final operation = requiredString(params, 'operation'),
          arguments = wireMap(params['arguments']);
      final session = params['session_id'] as String?;
      if (session != null && !state.conversations.any((c) => c.id == session)) {
        throw const BridgeFailure('not_found', '会话已不存在，未改投其他会话');
      }
      final jobId =
          params['_bridge_request_id'] as String? ?? const Uuid().v4();
      if (_jobs.containsKey(jobId)) return {'job_id': jobId};
      if (_jobs.values.where((j) => j['done'] != true).length >= 128) {
        throw const BridgeFailure('busy', '操作队列已满');
      }
      _jobs[jobId] = {'done': false};
      unawaited(
        Future<void>(() async {
          try {
            final value = await runZoned(
              () async => await switch (method) {
                'chat.call' => _chat.invoke(operation, arguments, session),
                'settings.call' => _settings.invoke(operation, arguments),
                'runtime.call' =>
                  operation.startsWith('backup.')
                      ? _backup(operation, arguments, jobId)
                      : operation.startsWith('ssh.')
                      ? _research.invoke(
                          operation.substring(4),
                          arguments,
                          requiredString(params, '_bridge_client_scope'),
                        )
                      : _runtime.invoke(operation, arguments),
                _ => _workspace.invoke(operation, arguments),
              },
              zoneValues: {_guiScopeKey: params['_bridge_client_scope']},
            );
            _jobs[jobId] = {'done': true, 'value': encodeHostValue(value)};
          } catch (error) {
            _jobs[jobId] = {
              'done': true,
              'error': {
                'code': error is BridgeFailure
                    ? error.code
                    : 'operation_failed',
                'message': error is BridgeFailure
                    ? error.message
                    : '操作未成功完成，请查看宿主中的会话或配置状态。',
              },
            };
          } finally {
            _revision++;
            final old = _jobs.entries
                .where((e) => e.value['done'] == true)
                .toList();
            for (final entry in old.take(
              (old.length - 256).clamp(0, old.length),
            )) {
              _jobs.remove(entry.key);
            }
          }
        }),
      );
      return {'job_id': jobId};
    }
    if (method.startsWith('host.preferences.')) {
      final prefs = container.read(sharedPrefsProvider);
      if (method == 'host.preferences.read') {
        return {
          'values': {for (final key in prefs.getKeys()) key: prefs.get(key)},
        };
      }
      final key = requiredString(params, 'key');
      const ownedKeys = {
        'chatSessionJournal.v1',
        'taskAcceptance.v1',
        'taskPlans.v1',
        'workOperations.v1',
        'workProcessJournal.v1',
        'workAgentJournal.v1',
        'workTaskJournal.v1',
        'roleEvolution.v1',
      };
      if (ownedKeys.contains(key)) {
        throw const BridgeFailure('owned_state', '任务状态由宿主维护，请使用对应操作');
      }
      if (params['has_expected'] == true &&
          (method == 'host.preferences.remove' ||
              method == 'host.preferences.write')) {
        try {
          await prefs.compareAndSet(
            key,
            params['expected'],
            method == 'host.preferences.remove' ? null : params['value'],
          );
        } catch (_) {
          throw const BridgeFailure('conflict', '设置已经变化或保存失败，请刷新后重试；没有覆盖新值。');
        }
      } else if (method == 'host.preferences.remove') {
        await prefs.remove(key);
      } else if (method == 'host.preferences.write') {
        final value = params['value'];
        if (value is String) {
          await prefs.setString(key, value);
        } else if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is List && value.every((v) => v is String)) {
          await prefs.setStringList(key, value.cast<String>());
        } else {
          throw const BridgeFailure('invalid_params', '偏好类型无效');
        }
      } else {
        throw const BridgeFailure('unsupported', '未知偏好操作');
      }
      _revision++;
      switch (key) {
        case ModelServiceRouting.storageKey:
          container.invalidate(modelServiceRoutingProvider);
        case ModelRouteGroupsController.storageKey:
          container.invalidate(modelRouteGroupsProvider);
        case ToolRegistryController.storageKey:
          container.invalidate(toolRegistrySettingsProvider);
        case SupervisorSettingsController.storageKey:
          container.invalidate(supervisorSettingsProvider);
        case RoleValidationSettingsController.storageKey:
          container.invalidate(roleValidationSettingsProvider);
      }
      return {'accepted': true};
    }
    if (method.startsWith('host.credentials.')) {
      final storage = container.read(secureStorageProvider);
      if (method == 'host.credentials.readAll') {
        return {'values': await storage.readAll()};
      }
      if (method == 'host.credentials.removeAll') {
        if (params['confirmed'] != true) {
          throw const BridgeFailure('confirmation_required', '清除凭据需要明确确认');
        }
        await storage.deleteAll();
        _revision++;
        return {'accepted': true};
      }
      final key = requiredString(params, 'key');
      if (method == 'host.credentials.read') {
        return {'value': await storage.read(key: key)};
      }
      if (method == 'host.credentials.write') {
        await storage.write(key: key, value: params['value'] as String?);
      } else if (method == 'host.credentials.remove') {
        await storage.delete(key: key);
      } else {
        throw const BridgeFailure('unsupported', '未知凭据操作');
      }
      _revision++;
      return {'accepted': true};
    }
    if (method.startsWith('host.library.')) {
      final files = container.read(libraryFileStoreProvider);
      if (method == 'host.library.root') return {'path': await files.rootPath};
      if (method == 'host.library.read') {
        final bytes = await files.readBytes(requiredString(params, 'path'));
        return {'bytes': bytes == null ? null : base64Encode(bytes)};
      }
      if (method == 'host.library.write') {
        return {
          'path': await files.writeBytes(
            id: requiredString(params, 'id'),
            fileName: requiredString(params, 'fileName'),
            image: params['image'] == true,
            bytes: base64Decode(requiredString(params, 'bytes')),
          ),
        };
      }
      if (method == 'host.library.delete') {
        await files.delete(requiredString(params, 'path'));
        return {'accepted': true};
      }
      throw const BridgeFailure('unsupported', '未知素材操作');
    }
    if (method.startsWith('host.memory.')) {
      final store = container.read(memoryStoreProvider);
      if (method == 'host.memory.location') {
        return {'path': await store.locationLabel()};
      }
      if (method == 'host.memory.read') {
        final markdown = await store.read();
        return {
          'markdown': markdown,
          'sha256': sha256.convert(utf8.encode(markdown ?? '')).toString(),
        };
      }
      if (method == 'host.memory.write') {
        await container.read(memoryRepositoryProvider).withMaintenance(
          () async {
            final current = await store.read();
            if (params['expected'] !=
                sha256.convert(utf8.encode(current ?? '')).toString()) {
              throw const BridgeFailure('conflict', '长期记忆已经变化，未覆盖，请重新加载后合并');
            }
            await store.write(params['markdown'] as String);
          },
        );
        _revision++;
        return {'accepted': true};
      }
      throw const BridgeFailure('unsupported', '未知记忆操作');
    }
    if (method == 'host.shutdown') {
      if (params['confirmed'] != true) {
        throw const BridgeFailure('confirmation_required', '请明确确认关闭执行宿主');
      }
      if (hasActiveShell ||
          hasWorkbenchJobs ||
          hasPendingLogin ||
          controller.runningConversationIds.isNotEmpty ||
          _llm.hasActive ||
          _research.hasActiveTransfers ||
          container.read(researchTerminalProvider).analyzing ||
          container.read(workAgentsProvider).records.any((a) => !a.terminal) ||
          container.read(workProcessesProvider).records.any((r) => r.active) ||
          _jobs.values.any((j) => j['done'] != true)) {
        throw const BridgeFailure('busy', '宿主仍有活动任务，请先停止任务并核验结果');
      }
      _shutdownRequested = true;
      Timer(
        const Duration(milliseconds: 100),
        () => unawaited(requestShutdown()),
      );
      return {'accepted': true};
    }
    return super.invoke(method, params);
  }

  @override
  Future<Map<String, Object?>> terminalBackup(Map<String, dynamic> args) async {
    final operation = requiredString(args, 'operation');
    if (operation == 'backup.preview') {
      final file = File(requiredString(args, 'path'));
      if (await file.length() > BackupCodec.maxBytes) {
        throw const BridgeFailure('too_large', '备份文件超过大小上限');
      }
      final bytes = await file.readAsBytes();
      final service = FullBackupService(
        container.read(appDatabaseProvider),
        container.read(libraryFileStoreProvider),
        container.read(memoryStoreProvider),
        container.read(sharedPrefsProvider),
        BackupJournal(),
      );
      final preview = await service.preview(bytes);
      return {
        'workbench': true,
        'title': '备份恢复预览',
        'data': {'path': file.path, 'sha256': sha256.convert(bytes).toString()},
        'fields': [
          {
            'key': 'summary',
            'label':
                '创建于 ${preview.createdAt} · 会话 ${preview.count('conversations')} · 文件 ${preview.count('library_items')}',
            'editable': false,
          },
          {
            'key': 'restorePreferences',
            'label': '恢复偏好（true/false）',
            'value': 'false',
            'editable': true,
          },
          {
            'key': 'restore',
            'label': '确认恢复为副本',
            'editable': false,
            'action': 'wb.backup.restore',
          },
        ],
      };
    }
    await _backup(operation, {
      ...args,
      'restorePreferences':
          args['restorePreferences'] == true ||
          args['restorePreferences'] == 'true',
    }, 'tui-backup');
    return {
      'workbench': true,
      'title': '备份与恢复',
      'fields': [
        {'key': 'result', 'label': '操作完成：${args['path']}', 'editable': false},
      ],
    };
  }

  Future<Object?> _backup(
    String operation,
    Map<String, dynamic> arguments,
    String jobId,
  ) async {
    if (_maintenance ||
        _llm.hasActive ||
        _research.hasActiveTransfers ||
        container.read(researchTerminalProvider).analyzing ||
        container.read(workAgentsProvider).records.any((r) => !r.terminal) ||
        container.read(workProcessesProvider).records.any((r) => r.active) ||
        _jobs.entries.any((e) => e.key != jobId && e.value['done'] != true)) {
      throw const BridgeFailure('busy', '请等待其他任务、模型请求及文件传输结束后再维护数据');
    }
    _maintenance = true;
    _revision++;
    try {
      await controller.prepareDataMaintenance();
      return await databaseHub.maintenance(
        () =>
            container.read(memoryRepositoryProvider).withMaintenance(() async {
              final service = FullBackupService(
                container.read(appDatabaseProvider),
                container.read(libraryFileStoreProvider),
                container.read(memoryStoreProvider),
                container.read(sharedPrefsProvider),
                BackupJournal(),
              );
              final path = requiredString(arguments, 'path');
              if (!p.isAbsolute(path)) {
                throw const BridgeFailure('invalid_params', '备份文件须为绝对路径');
              }
              final file = File(path);
              if (operation == 'backup.export') {
                await writeAtomic(file, await service.exportBackup());
                return null;
              }
              if (operation != 'backup.restore') {
                throw const BridgeFailure('unsupported', '未知备份操作');
              }
              if (await file.length() > BackupCodec.maxBytes) {
                throw const BridgeFailure('too_large', '备份文件超过大小上限');
              }
              final bytes = await file.readAsBytes();
              if (sha256.convert(bytes).toString() != arguments['sha256']) {
                throw const BridgeFailure('conflict', '备份已变化，请重新查看');
              }
              final preview = await service.preview(bytes);
              await service.restoreCopies(
                preview,
                restorePreferences: arguments['restorePreferences'] == true,
              );
              container.invalidate(taskPlansProvider);
              container.invalidate(taskAcceptanceProvider);
              container.invalidate(workMemoryProvider);
              if (arguments['restorePreferences'] == true) {
                container.invalidate(settingsControllerProvider);
                container.invalidate(modelServiceRoutingProvider);
                container.invalidate(modelRouteGroupsProvider);
                container.invalidate(toolRegistrySettingsProvider);
                container.invalidate(supervisorSettingsProvider);
                container.invalidate(roleValidationSettingsProvider);
              }
              container.invalidate(chatControllerProvider);
              await container.read(settingsControllerProvider.future);
              await container.read(chatControllerProvider.future);
              return null;
            }),
      );
    } finally {
      _maintenance = false;
      _revision++;
      final db = container.read(appDatabaseProvider);
      db.markTablesUpdated(db.allTables);
    }
  }

  Map<String, Object?> _guiSnapshot(Map<String, dynamic> params) {
    if (params['known_revision'] == revision) {
      return {'unchanged': true, 'revision': revision};
    }
    final settings = container.read(settingsControllerProvider).requireValue;
    final approvals = container.read(workApprovalsProvider),
        questions = container.read(workQuestionsProvider);
    final rounds = container.read(workRoundsProvider);
    final response = <String, Object?>{
      'revision': revision,
      'maintenance': _maintenance,
      'settings_revision': _settingsRevision,
      if (params['known_settings_revision'] != _settingsRevision)
        'settings': encodeSettingsState(settings),
      'gui_actions': [
        for (final action in _guiActions.values)
          if (action.scope == params['_bridge_client_scope']) action.request,
      ],
      'chat_patch': _chatProjections
          .putIfAbsent(
            params['_bridge_client_scope'] as String,
            HostChatProjection.new,
          )
          .project(
            state,
            params['session_id'] as String? ?? state.currentId,
            params['chat_cursor'] as int? ?? 0,
          ),
      'session_meta': {
        for (final c in state.conversations)
          c.id: {
            'thinking': controller.thinkingForSession(c.id),
            'effort': controller.effortForSession(c.id).name,
            'error': controller.errorForSession(c.id),
            'retry': controller.retryForSession(c.id),
            'retry_operation': encodeRetry(
              controller.retryOperationForSession(c.id),
            ),
            'task': controller.taskSnapshotFor(c.id),
            'compacting': controller.isContextCompacting(c.id),
          },
      },
      'runtime': {
        'research': encodeResearch(container.read(researchTerminalProvider)),
        'approvals': [
          for (final a in approvals)
            {
              'id': a.id,
              'conversationId': a.conversationId,
              'sourceAgentId': a.sourceAgentId,
              'toolCallId': a.toolCallId,
              'tool': a.tool,
              'arguments': a.arguments,
              'target': a.target,
              'reason': a.reason,
            },
        ],
        'questions': [
          for (final q in questions)
            {
              'id': q.id,
              'conversationId': q.conversationId,
              'sourceAgentId': q.sourceAgentId,
              'assistantId': q.assistantId,
              'questions': [
                for (final x in q.questions)
                  {
                    'id': x.id,
                    'question': x.question,
                    'options': x.options,
                    'multiple': x.multiple,
                    'required': x.required,
                  },
              ],
            },
        ],
        'rounds': rounds.map(
          (k, v) => MapEntry(k, {
            'runId': v.runId,
            'limit': v.limit,
            'step': v.step,
            'reviewAhead': v.reviewAhead,
            'autoExtend': v.autoExtend,
            'used': v.used,
            'reviewedLimit': v.reviewedLimit,
            'reviewing': v.reviewing,
            'finishing': v.finishing,
            'active': v.active,
            'revision': v.revision,
            'note': v.note,
            'pauseRequested': v.pauseRequested,
            'paused': v.paused,
          }),
        ),
        'policies': container
            .read(sessionPolicyProvider)
            .map((k, v) => MapEntry(k, v.toJson())),
        'modelChoices': container.read(conversationModelChoiceProvider),
        'workspaceBindings': container.read(
          conversationWorkspaceBindingsProvider,
        ),
        'changes': _cached(
          'changes',
          container.read(workChangesProvider),
          () => container
              .read(workChangesProvider)
              .map((v) => v.toJson())
              .toList(),
        ),
        'tasks': container
            .read(workTaskRuntimeProvider)
            .map(
              (v) => {
                ...v.toJson(),
                'canStop': container
                    .read(workTaskRuntimeProvider.notifier)
                    .canStop(v.id),
                'stopRequested': v.stopRequested,
                'logsTruncated': v.logsTruncated,
                'logs': v.logs
                    .map((l) => {'text': l.text, 'isStderr': l.isStderr})
                    .toList(),
              },
            )
            .toList(),
        'plans': container
            .read(taskPlansProvider)
            .map((k, v) => MapEntry(k, v.toJson())),
        'acceptance': container
            .read(taskAcceptanceProvider)
            .map((k, v) => MapEntry(k, v.toJson())),
        'acceptanceDrafts': {
          for (final c in state.conversations)
            c.id: container
                .read(taskAcceptanceProvider.notifier)
                .draftCriteriaForConversation(c.id)
                .toJson(),
        },
        'agents': container
            .read(workAgentsProvider)
            .records
            .map(
              (v) => {
                ...v.toJson(),
                'conversationId': v.conversationId,
                'taskId': v.taskId,
                'limits': v.limits.toJson(),
                'external': v.external,
                'restored': v.restored,
                'created_at': v.createdAt.toIso8601String(),
                'logs': v.logs,
                'files': v.files,
              },
            )
            .toList(),
        'processes': container
            .read(workProcessesProvider)
            .records
            .map(
              (v) => {
                ...v.toJson(),
                'conversationId': v.conversationId,
                'taskId': v.taskId,
                'service': v.service,
                'ownerAgentId': v.ownerAgentId,
                'hookId': v.hookId,
                'restored': v.restored,
                'started_at': v.startedAt.toIso8601String(),
                'finished_at': v.finishedAt?.toIso8601String(),
              },
            )
            .toList(),
        'hooks': container
            .read(workHooksProvider)
            .records
            .map(
              (r) => {
                'definition': r.definition.toJson(),
                'status': r.status,
                'error': r.error,
                'processId': r.processId,
                'lastTriggeredAt': r.lastTriggeredAt?.toIso8601String(),
                'launching': r.launching,
                'unavailableReason': container
                    .read(workHooksProvider)
                    .runUnavailableReason(r.definition.id),
              },
            )
            .toList(),
        'hookBindings': {
          for (final c in state.conversations)
            c.id: container.read(workHooksProvider).boundRoot(c.id),
        },
        'agentModels': container
            .read(workAgentModelPoolProvider)
            ?.map((v) => v.toJson())
            .toList(),
        'roleCandidates': container
            .read(roleEvolutionProvider)
            .map((v) => v.toJson())
            .toList(),
        'modelUsage': container
            .read(modelUsageControllerProvider)
            .map((v) => v.toJson())
            .toList(),
        'insights': _cached(
          'insights',
          container.read(workSessionInsightsProvider),
          () => container
              .read(workSessionInsightsProvider)
              .map(
                (k, v) => MapEntry(k, {
                  'model': v.model,
                  'contextBudgetTokens': v.contextBudgetTokens,
                  'messages': v.messages.map(encodeRequest).toList(),
                  'tools': v.tools.map(encodeTool).toList(),
                  'requests': v.requests.map(
                    (id, u) => MapEntry(id, u == null ? null : encodeUsage(u)),
                  ),
                  'pricingKeys': v.pricingKeys,
                  'requestKinds': v.requestKinds.map(
                    (id, kind) => MapEntry(id, kind.name),
                  ),
                }),
              ),
        ),
        'steering': {
          for (final c in state.conversations)
            c.id: container.read(workTaskSteeringProvider).snapshot(c.id),
        },
        'logs': _cached(
          'logs',
          container.read(workRuntimeLogsProvider),
          () => container
              .read(workRuntimeLogsProvider)
              .map((v) => v.toJson())
              .toList(),
        ),
        'memory': {
          for (final c in state.conversations)
            c.id: {
              ...container.read(workMemoryProvider).snapshot(c.id),
              'agents': {
                for (final id
                    in container.read(workMemoryProvider).agentScopes(c.id))
                  id: container
                      .read(workMemoryProvider)
                      .snapshot(c.id, agentId: id),
              },
            },
        },
        'memoryCorrupt': container.read(workMemoryProvider).corrupt,
        'memoryCorruptSource': container.read(workMemoryProvider).corruptSource,
        'memoryCorruptDigest': container.read(workMemoryProvider).corruptDigest,
      },
    };
    final runtime = response['runtime'] as Map<String, Object?>;
    final known = wireMap(params['known_runtime_versions']);
    final changed = <String, Object?>{}, versions = <String, int>{};
    for (final entry in runtime.entries) {
      var cached = _wireRuntime[entry.key];
      if (cached == null || !identical(cached.value, entry.value)) {
        final encoded = jsonEncode(entry.value);
        if (cached == null || cached.encoded != encoded) {
          cached = (
            value: entry.value,
            encoded: encoded,
            version: ++_nextProjectionVersion,
          );
          _wireRuntime[entry.key] = cached;
        }
      }
      versions[entry.key] = cached.version;
      if (known[entry.key] != cached.version) changed[entry.key] = cached.value;
    }
    response['runtime'] = changed;
    response['runtime_versions'] = versions;
    return response;
  }

  void disposeProjection() {
    closeWorkbench();
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    _removeListeners?.call();
    for (final action in _guiActions.values) {
      if (!action.result.isCompleted) {
        action.result.completeError(StateError('宿主已关闭'));
      }
    }
    _guiActions.clear();
    _llm.close();
  }
}
