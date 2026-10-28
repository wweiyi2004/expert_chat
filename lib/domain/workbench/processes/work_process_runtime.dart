import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import '../../../platform/foundation.dart';

import '../../desktop/command_runner.dart';
import '../../desktop/workspace_tools.dart';
import '../../llm/llm_provider.dart';
import '../../chat/task_window.dart';
import '../../research/research_workspace.dart';
import '../../research/research_ssh_contract.dart'
    show ResearchSshExecException;
import '../../research/shell_quoting.dart';

enum WorkProcessStatus {
  starting,
  running,
  stopping,
  completed,
  failed,
  cancelled,
  interrupted,
}

class WorkProcessResult {
  const WorkProcessResult({
    this.exitCode,
    this.output = '',
    this.cancelled = false,
    this.timedOut = false,
    this.outputs = const [],
  });
  final int? exitCode;
  final String output;
  final bool cancelled, timedOut;
  final List<String> outputs;
}

typedef WorkProcessExecutor =
    Future<WorkProcessResult> Function(
      CancelToken token,
      WorkspaceCommandOutput onOutput,
    );

class WorkProcessRecord {
  WorkProcessRecord({
    required this.id,
    required this.conversationId,
    required this.taskId,
    required this.command,
    required this.target,
    required this.service,
    required this.execute,
    this.ownerAgentId,
    this.hookId,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.now();
  final String id, conversationId, taskId, command, target;
  final String? ownerAgentId, hookId;
  final bool service;
  final WorkProcessExecutor execute;
  final DateTime startedAt;
  DateTime? finishedAt;
  WorkProcessStatus status = WorkProcessStatus.starting;
  int? exitCode;
  String log = '', error = '';
  bool logsTruncated = false;
  bool restored = false;
  List<String> outputs = const [];
  final CancelToken token = CancelToken();
  bool get active =>
      status == WorkProcessStatus.starting ||
      status == WorkProcessStatus.running ||
      status == WorkProcessStatus.stopping;
  Map<String, dynamic> toJson() => {
    'id': id,
    'command': command,
    'target': target,
    'kind': service ? 'service' : 'command',
    'status': status.name,
    'exit_code': exitCode,
    'outputs': outputs,
    'log': log,
    'logs_truncated': logsTruncated,
    if (error.isNotEmpty) 'error': error,
  };
}

class WorkProcessEvent {
  const WorkProcessEvent({
    required this.id,
    required this.conversationId,
    required this.taskId,
    required this.processId,
    required this.content,
    this.ownerAgentId,
  });
  final String id, conversationId, taskId, processId, content;
  final String? ownerAgentId;
}

/// Owns process lifetimes independently of a single model request. An executor
/// must hold an independently opened, permission-checked workspace session.
class WorkProcessRuntime extends ChangeNotifier {
  final Map<String, WorkProcessRecord> _records = {};
  final _events = StreamController<WorkProcessEvent>.broadcast();
  int _sequence = 0;
  bool _disposed = false;
  Timer? _outputTimer;
  List<WorkProcessRecord> get records => List.unmodifiable(_records.values);
  Stream<WorkProcessEvent> get events => _events.stream;
  WorkProcessRecord? record(String id) => _records[id];

  String start({
    required String conversationId,
    required String taskId,
    required String command,
    required String target,
    required WorkProcessExecutor execute,
    bool service = false,
    String? ownerAgentId,
    String? hookId,
    String? requestedId,
  }) {
    TaskWindow.current?.ensureOpen();
    if (_disposed) throw StateError('进程运行时已关闭');
    if (command.trim().isEmpty) throw const FormatException('命令不能为空');
    final id =
        requestedId ??
        'process_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';
    if (!RegExp(r'^process_[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
        _records.containsKey(id)) {
      throw StateError('进程请求身份无效或已存在');
    }
    final r = WorkProcessRecord(
      id: id,
      conversationId: conversationId,
      taskId: taskId,
      command: command,
      target: target,
      service: service,
      execute: execute,
      ownerAgentId: ownerAgentId,
      hookId: hookId,
    );
    _records[id] = r;
    notifyListeners();
    scheduleMicrotask(() => unawaited(_run(r)));
    return id;
  }

  Future<void> _run(WorkProcessRecord r) async {
    final detachWindow = TaskWindow.current?.attach(r.token);
    try {
      if (r.token.isCancelled) {
        r.status = WorkProcessStatus.cancelled;
        return;
      }
      r.status = WorkProcessStatus.running;
      _notify();
      final result = await r.execute(r.token, (text, stderr) {
        if (_disposed) return;
        r.log += stderr ? '[stderr] $text' : text;
        if (r.log.length > 64000) {
          r.log = r.log.substring(r.log.length - 64000);
          r.logsTruncated = true;
        }
        _outputTimer ??= Timer(const Duration(milliseconds: 80), () {
          _outputTimer = null;
          _notify();
        });
      });
      r.exitCode = result.exitCode;
      r.outputs = result.outputs;
      if (r.log.isEmpty) {
        r.log = result.output.length > 64000
            ? result.output.substring(result.output.length - 64000)
            : result.output;
      }
      r.status = result.cancelled || r.token.isCancelled
          ? WorkProcessStatus.cancelled
          : result.exitCode == 0 && !result.timedOut
          ? WorkProcessStatus.completed
          : WorkProcessStatus.failed;
      if (result.timedOut) r.error = '命令超时，已终止';
    } catch (error) {
      r.status = r.token.isCancelled
          ? WorkProcessStatus.cancelled
          : WorkProcessStatus.failed;
      r.error = '$error';
    } finally {
      detachWindow?.call();
      r.finishedAt = DateTime.now();
      _notify();
      if (!_disposed) {
        _events.add(
          WorkProcessEvent(
            id: 'process_event_${_sequence++}',
            conversationId: r.conversationId,
            taskId: r.taskId,
            processId: r.id,
            ownerAgentId: r.ownerAgentId,
            content:
                '${r.service ? '后台服务已退出' : '后台命令已完成'}：${r.id}\n命令：${r.command}\n状态：${r.status.name}；退出码：${r.exitCode ?? '未知'}\n${r.error}\n产物：${r.outputs.join(', ')}\n日志末尾：\n${r.log.length > 12000 ? r.log.substring(r.log.length - 12000) : r.log}',
          ),
        );
      }
    }
  }

  void stop(String id) {
    final r = _records[id];
    if (r == null || !r.active) return;
    r.status = WorkProcessStatus.stopping;
    r.token.cancel('用户停止后台任务');
    _notify();
  }

  String restart(String id, {String? requestedId}) {
    final r = _records[id] ?? (throw StateError('进程不存在'));
    if (r.restored) throw StateError('应用重启后执行连接已释放，请重新批准并启动命令');
    if (r.active) throw StateError('先停止进程并等待退出，再重启');
    return start(
      conversationId: r.conversationId,
      taskId: r.taskId,
      command: r.command,
      target: r.target,
      execute: r.execute,
      service: r.service,
      ownerAgentId: r.ownerAgentId,
      hookId: r.hookId,
      requestedId: requestedId,
    );
  }

  List<Map<String, dynamic>> journal() => _records.values
      .toList()
      .reversed
      .take(100)
      .map(
        (r) => {
          ...r.toJson(),
          'conversationId': r.conversationId,
          'taskId': r.taskId,
          'ownerAgentId': r.ownerAgentId,
          'hookId': r.hookId,
          'service': r.service,
          'log': r.log.length > 8000
              ? r.log.substring(r.log.length - 8000)
              : r.log,
        },
      )
      .toList();

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
        final saved = WorkProcessStatus.values.byName(j['status'] as String);
        final interrupted =
            !liveProjection &&
            (saved == WorkProcessStatus.starting ||
                saved == WorkProcessStatus.running ||
                saved == WorkProcessStatus.stopping);
        final r =
            WorkProcessRecord(
                id: j['id'] as String,
                conversationId: j['conversationId'] as String,
                taskId: j['taskId'] as String,
                command: j['command'] as String,
                target: j['target'] as String,
                service: j['service'] == true,
                ownerAgentId: j['ownerAgentId'] as String?,
                hookId: j['hookId'] as String?,
                startedAt: DateTime.tryParse(j['started_at'] as String? ?? ''),
                execute: (_, _) async => throw StateError('历史进程不能自动重放'),
              )
              ..restored = liveProjection ? j['restored'] == true : true
              ..status = interrupted ? WorkProcessStatus.interrupted : saved
              ..exitCode = (j['exit_code'] as num?)?.toInt()
              ..log = j['log'] as String? ?? ''
              ..error = interrupted
                  ? '应用已重启，进程未重新连接；请先检查本机或 SSH 状态。'
                  : j['error'] as String? ?? '';
        r.finishedAt = DateTime.tryParse(j['finished_at'] as String? ?? '');
        r.outputs = (j['outputs'] as List? ?? []).cast<String>();
        r.logsTruncated = j['logs_truncated'] == true;
        _records[r.id] = r;
      } catch (_) {}
    }
  }

  /// Uses exactly the existing session target and shell grant validation.
  /// Services have no artificial ten-minute timeout; they stop on cancellation,
  /// process exit, SSH disconnect or application shutdown.
  static Future<WorkProcessResult> executeInSession(
    WorkToolSession session,
    String command,
    bool service,
    CancelToken token,
    WorkspaceCommandOutput onOutput, {
    int timeoutSeconds = 600,
  }) async {
    WorkspaceCommandOutcome? outcome;
    final timeout = service
        ? const Duration(days: 3650)
        : Duration(seconds: timeoutSeconds.clamp(1, 86400));
    String output;
    if (session is WorkspaceToolSession) {
      await session.authorizeCommand();
      if (token.isCancelled) throw token.cancelError!;
      output = await runWorkspaceCommand(
        command,
        session.workspace.root,
        timeout,
        token,
        onOutput: onOutput,
        onComplete: (o) => outcome = o,
      );
    } else if (session is ResearchWorkspaceSession) {
      session.validate();
      if (token.isCancelled) throw token.cancelError!;
      try {
        output = await session.command(
          'cd ${shellSingleQuote(session.root)} && $command',
          timeout,
          token,
          onOutput: onOutput,
          onComplete: (o) => outcome = o,
        );
      } on ResearchSshExecException catch (error) {
        return WorkProcessResult(
          exitCode: error.exitCode,
          output: '${error.stdoutText}\n${error.stderrText}',
          cancelled: token.isCancelled,
        );
      }
    } else {
      throw UnsupportedError('当前工作区没有后台命令执行能力');
    }
    return WorkProcessResult(
      exitCode: outcome?.exitCode,
      output: output,
      cancelled: token.isCancelled || outcome?.cancelled == true,
      timedOut: outcome?.timedOut == true,
    );
  }

  static const toolNames = {
    'work_start_process',
    'work_list_processes',
    'work_process_status',
    'work_stop_process',
    'work_restart_process',
  };
  static const tools = <ToolSpec>[
    ToolSpec(
      name: 'work_start_process',
      description:
          '启动后台命令或常驻服务，立即返回进程 ID。完成/退出自动通知当前任务，勿轮询等待。service=true 用于开发服务器等常驻进程；仍使用当前工作区与批准权限。',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {'type': 'string'},
          'service': {'type': 'boolean'},
          'timeout_seconds': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 86400,
          },
        },
        'required': ['command'],
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_list_processes',
      description: '列出当前会话后台命令和常驻服务。',
      parameters: {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_process_status',
      description: '读取后台进程状态、退出码、真实日志与产物信息。',
      parameters: {
        'type': 'object',
        'properties': {
          'process_id': {'type': 'string'},
        },
        'required': ['process_id'],
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_stop_process',
      description: '停止当前会话的后台进程（本机终止进程树，SSH 请求停止执行通道）。',
      parameters: {
        'type': 'object',
        'properties': {
          'process_id': {'type': 'string'},
        },
        'required': ['process_id'],
        'additionalProperties': false,
      },
    ),
    ToolSpec(
      name: 'work_restart_process',
      description: '按原命令、原目标和原权限重新启动已结束的后台进程。',
      parameters: {
        'type': 'object',
        'properties': {
          'process_id': {'type': 'string'},
        },
        'required': ['process_id'],
        'additionalProperties': false,
      },
    ),
  ];
  String callTool(
    String conversationId,
    String name,
    Map<String, dynamic> args,
  ) {
    if (name == 'work_list_processes') {
      return jsonEncode(
        records
            .where((r) => r.conversationId == conversationId)
            .map((r) => r.toJson())
            .toList(),
      );
    }
    final r = _records[args['process_id']];
    if (r == null || r.conversationId != conversationId) {
      throw StateError('进程不属于当前会话');
    }
    if (name == 'work_process_status') return jsonEncode(r.toJson());
    if (name == 'work_stop_process') {
      stop(r.id);
      return '已请求停止';
    }
    if (name == 'work_restart_process') {
      return jsonEncode({'process_id': restart(r.id)});
    }
    throw StateError('启动进程需要当前会话的独立执行器');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _outputTimer?.cancel();
    for (final r in _records.values.where((r) => r.active)) {
      r.token.cancel('应用已关闭');
    }
    unawaited(_events.close());
    super.dispose();
  }
}
