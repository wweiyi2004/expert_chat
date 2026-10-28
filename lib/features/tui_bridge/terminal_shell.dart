part of 'backend.dart';

class _ShellJob {
  _ShellJob(
    this.id,
    this.scope,
    this.session,
    this.command,
    this.target,
    this.remote,
  );
  final String id, scope, session, command, target;
  final bool remote;
  final token = CancelToken();
  final output = HostTerminalOutput();
  final started = DateTime.now();
  DateTime? finished;
  bool done = false, cancelled = false, timedOut = false;
  int? exitCode;
  String error = '';
  Map<String, Object?> view(Map<String, dynamic> args) => {
    'job_id': id,
    'session_id': session,
    'command': command,
    'target': target,
    'done': done,
    'cancelled': cancelled,
    'stopping': token.isCancelled && !done,
    'remote': remote,
    'timed_out': timedOut,
    'exit_code': exitCode,
    'error': error,
    'elapsed_ms': (finished ?? DateTime.now())
        .difference(started)
        .inMilliseconds,
    ...output.read(
      (args['cursor'] as num?)?.toInt() ?? 0,
      (args['generation'] as num?)?.toInt() ?? -1,
    ),
  };
}

extension TuiShellCommands on ControllerBridgeBackend {
  Future<Map<String, Object?>> _shellCommand(
    String method,
    Map<String, dynamic> args,
  ) async {
    final action = requiredString(
      args,
      method == 'terminal.query' ? 'topic' : 'action',
    );
    final id = requiredString(args, 'session_id');
    _session(id);
    final scope = requiredString(args, '_bridge_client_scope');
    if (method == 'terminal.query') {
      if (action != 'shell.status' && action != 'shell.latest') {
        throw const BridgeFailure('unsupported', '未知命令查询');
      }
      final job = args['job_id'] is String
          ? _shellJobs[args['job_id']]
          : _shellJobs.values.where((job) => job.session == id).lastOrNull;
      if (job == null || job.session != id) {
        throw const BridgeFailure('not_found', '此会话没有命令记录；在输入栏使用 !命令');
      }
      return job.view(args);
    }
    if (action == 'shell.cancel') {
      final job = _shellJobs[requiredString(args, 'job_id')];
      if (job == null || job.session != id) {
        throw const BridgeFailure('not_found', '命令已结束或不存在');
      }
      if (job.scope != scope) {
        throw const BridgeFailure('forbidden', '只能中断此终端发起的命令');
      }
      if (!job.done) job.token.cancel('用户中断命令');
      return job.view(args);
    }
    if (action != 'shell.start') {
      throw const BridgeFailure('unsupported', '未知命令操作');
    }
    if (args['explicit'] != true) {
      throw const BridgeFailure('invalid_params', '命令需要由用户在输入栏明确发起');
    }
    final command = requiredString(args, 'command');
    if (command.trim().isEmpty ||
        command.contains('\u0000') ||
        command.length > 65536) {
      throw const BridgeFailure('invalid_params', '命令须非空且不超过 65536 字符');
    }
    if (_shellJobs.values.any((job) => job.session == id && !job.done)) {
      throw const BridgeFailure('busy', '当前会话已有命令运行；使用 /shell 查看或中断');
    }
    if (_shellJobs.values.where((job) => !job.done).length >= 8) {
      throw const BridgeFailure('busy', '同时运行的手动命令已达上限');
    }
    final policy = _policy(id), token = CancelToken();
    WorkToolSession work;
    if (policy.sshProfileId.isNotEmpty) {
      if (args['workspace_id'] != 'ssh:${policy.sshProfileId}' ||
          args['cwd'] != policy.remoteRoot) {
        throw const BridgeFailure('conflict', '工作目录已变化，请核对后重新输入命令');
      }
      work = await container
          .read(researchTerminalProvider.notifier)
          .openWorkSession(policy.sshProfileId, policy.remoteRoot);
    } else {
      final binding = container.read(conversationWorkspaceBindingsProvider)[id];
      if (binding == null || args['workspace_id'] != binding) {
        throw const BridgeFailure('conflict', '请先选择当前工作区，再执行命令');
      }
      final local = await WorkspaceToolSession.open(
        container.read(desktopWorkspaceHostProvider),
        binding,
        token,
      );
      try {
        if (args['cwd'] != local.workspace.root) {
          throw const BridgeFailure('conflict', '工作目录已变化，请核对后重试');
        }
        await local.authorizeCommand();
      } catch (_) {
        await local.close();
        rethrow;
      }
      work = local;
    }
    // Opening a workspace awaits I/O. Recheck ownership before starting a process.
    if (_releasedScopes.contains(scope)) {
      await work.close();
      throw const BridgeFailure('disconnected', '终端已断开，未执行命令');
    }
    if (_shellJobs.values.any((job) => job.session == id && !job.done)) {
      await work.close();
      throw const BridgeFailure('busy', '当前会话已有命令运行');
    }
    while (_shellJobs.length >= 50) {
      final old = _shellJobs.values.where((job) => job.done).firstOrNull;
      if (old == null) break;
      _shellJobs.remove(old.id);
    }
    final job = _ShellJob(
      const Uuid().v4(),
      scope,
      id,
      command,
      work.target,
      policy.sshProfileId.isNotEmpty,
    );
    _shellJobs[job.id] = job;
    _draftProtected[id] = (_draftProtected[id] ?? 0) + 1;
    unawaited(_runShell(job, work));
    return job.view(args);
  }

  Future<void> _runShell(_ShellJob job, WorkToolSession work) async {
    final detachWindow = TaskWindow.current?.attach(job.token);
    try {
      final result = await work.call(
        'work_run_command',
        {'command': job.command, 'timeout_seconds': 600},
        job.token,
        onOutput: (text, isError) => job.output.add(text),
        onComplete: (outcome) {
          job.exitCode = outcome.exitCode;
          job.cancelled = outcome.cancelled;
          job.timedOut = outcome.timedOut;
        },
      );
      if (job.exitCode == null && !job.cancelled && !job.timedOut) {
        final match = RegExp(r'退出码[：:]\s*(-?\d+)').firstMatch(result);
        if (match != null) job.exitCode = int.tryParse(match.group(1)!);
      }
      if (job.output.read(0, -1)['text'] == '') job.output.add(result);
    } catch (error) {
      if (job.token.isCancelled) {
        job.cancelled = true;
      } else {
        job.error = error is WorkspaceHostException
            ? error.message
            : error is StateError
            ? error.message
            : '命令执行失败，请检查工作目录、Shell 与连接状态';
      }
    } finally {
      detachWindow?.call();
      job.cancelled = job.cancelled || job.token.isCancelled;
      job.done = true;
      job.finished = DateTime.now();
      try {
        await work.close();
      } finally {
        final count = (_draftProtected[job.session] ?? 1) - 1;
        if (count <= 0) {
          _draftProtected.remove(job.session);
        } else {
          _draftProtected[job.session] = count;
        }
        await _cleanupOwnedDrafts(job.scope);
      }
    }
  }
}
