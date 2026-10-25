import 'package:expert_chat/core/app_toast.dart';
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'remote_automation_panel.dart';
import 'remote_workspace_panel.dart';
import '../settings/widgets/text_value_dialog.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:crypto/crypto.dart';

class RemoteTasksPage extends StatefulWidget {
  const RemoteTasksPage({super.key, this.client});
  final Dio? client;
  @override
  State<RemoteTasksPage> createState() => _RemoteTasksPageState();
}

class _RemoteTasksPageState extends State<RemoteTasksPage> {
  final _url = TextEditingController(text: 'http://127.0.0.1:47831');
  final _token = TextEditingController();
  final _goal = TextEditingController();
  final _storage = const FlutterSecureStorage();
  final _manualAutomationEvents = <String, Map<String, String>>{};
  late final Dio _dio;
  List<dynamic> _tasks = [];
  final List<dynamic> _events = [];
  int _cursor = 0;
  String? _error;
  String? _pendingId;
  Map<String, dynamic>? _pendingSubmission;
  final _pendingByHost = <String, Map<String, dynamic>>{};
  String? _submissionEndpoint;
  List<String> _allowedPolicies = ['request'];
  String _policy = 'request';
  final _roundLimit = TextEditingController(text: '20');
  int _roundCeiling = 200, _defaultRoundLimit = 20;
  bool _allowAutoBudget = false, _autoBudget = false;
  bool _busy = false;
  bool _connected = false;
  bool _protectedTunnel = false;
  Timer? _timer;
  CancelToken? _pollCancel;
  final _stopping = <String>{};
  int _connectionEpoch = 0;
  final List<Map<String, dynamic>> _computers = [];
  bool _historyTruncated = false;
  String _normalizedAddress(String value) =>
      (Uri.tryParse(value.trim())?.toString() ?? value.trim()).replaceFirst(
        RegExp(r'/+$'),
        '',
      );
  String _deviceKey(String address) =>
      '${_normalizedAddress(address)}|${sha256.convert(utf8.encode(_token.text.trim()))}';
  Future<void> _savePending() => _storage.write(
    key: 'remote_host_pending_by_host_v1',
    value: jsonEncode(_pendingByHost),
  );
  void _activatePending(String address) {
    final endpoint = _deviceKey(address);
    if (_submissionEndpoint == endpoint) return;
    final hadEndpoint = _submissionEndpoint != null;
    _submissionEndpoint = endpoint;
    _pendingSubmission = _pendingByHost[endpoint] == null
        ? null
        : Map<String, dynamic>.from(_pendingByHost[endpoint]!);
    _pendingId = _pendingSubmission?['id'] as String?;
    if (_pendingSubmission != null) {
      _goal.text = _pendingSubmission!['goal'] as String;
      _policy = _pendingSubmission!['policy'] as String? ?? 'request';
      _roundLimit.text = '${_pendingSubmission!['roundLimit'] ?? 20}';
      _autoBudget = _pendingSubmission!['autoBudgetExtension'] == true;
    } else if (hadEndpoint) {
      _goal.clear();
      _policy = 'request';
      _autoBudget = false;
      _roundLimit.text = '$_defaultRoundLimit';
    }
  }

  int _timestamp(Map task) =>
      DateTime.tryParse(
        task['updatedAt'] as String? ?? '',
      )?.microsecondsSinceEpoch ??
      0;
  bool _notOlder(Map candidate, Map current) {
    final next = int.tryParse(candidate['version']?.toString() ?? '');
    final before = int.tryParse(current['version']?.toString() ?? '');
    if (next != null && before != null) return next >= before;
    if (next != null) return true;
    if (before != null) return false;
    return _timestamp(candidate) >= _timestamp(current);
  }

  Future<void> _stopTask(Map task) async {
    final id = task['id'] as String, epoch = _connectionEpoch;
    if (_stopping.contains(id)) return;
    setState(() => _stopping.add(id));
    _pollCancel?.cancel('Stop has priority over polling');
    try {
      final result = await _request('tasks/$id/stop', body: {}) as Map;
      if (!mounted || epoch != _connectionEpoch) return;
      setState(() {
        _tasks = _tasks
            .map(
              (current) => current['id'] == id && _notOlder(result, current)
                  ? Map<String, dynamic>.from(result)
                  : current,
            )
            .toList();
      });
    } catch (error) {
      if (mounted && epoch == _connectionEpoch) {
        setState(() => _error = '停止请求尚未确认，请重试并查看电脑状态');
      }
    } finally {
      if (mounted) setState(() => _stopping.remove(id));
    }
  }

  Widget _monoBlock(String text) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 280),
    child: SingleChildScrollView(
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    ),
  );
  Future<void> _extendBudget(Map task) async {
    final epoch = _connectionEpoch;
    final remaining =
        _roundCeiling - (task['roundLimit'] as int? ?? _defaultRoundLimit);
    if (remaining <= 0) return;
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextValueDialog(
        title: '追加轮次并继续此任务',
        initialText: '${remaining < 5 ? remaining : 5}',
        label: '追加数量（最多 $remaining）',
        description: '保留当前历史和已完成操作，从轮次边界继续，不重新提交目标。',
        maxLines: 1,
        maxLength: 4,
      ),
    );
    if (!mounted || epoch != _connectionEpoch || text == null) return;
    final extra = int.tryParse(text.trim());
    if (extra == null || extra < 1 || extra > remaining) {
      setState(() => _error = '请输入 1 到 $remaining 之间的整数');
      return;
    }
    await _run(() async {
      await _request(
        'tasks/${task['id']}/budget',
        body: {
          'version': task['version'] ?? task['updatedAt'],
          'additionalRounds': extra,
        },
      );
      await _refresh();
    });
  }

  String _policyLabel(String value) => switch (value) {
    'full' => '完全访问',
    'assisted' => '模型辅助批准',
    _ => '请求批准',
  };
  Future<void> _download(Map artifact) async {
    final epoch = _connectionEpoch;
    final endpoint = _url.text.trim().replaceFirst(RegExp(r'/$'), '');
    final credential = _token.text.trim();
    await _request('tasks');
    final directory = await getApplicationDocumentsDirectory();
    final folder = await Directory(
      '${directory.path}/remote_artifacts',
    ).create(recursive: true);
    final name = (artifact['path'] as String)
        .split(RegExp(r'[/\\]'))
        .last
        .replaceAll(RegExp(r'[^\w.\-\u4e00-\u9fff]'), '_');
    final file = File(
      '${folder.path}/${DateTime.now().microsecondsSinceEpoch}_$name',
    );
    try {
      await _dio.download(
        '$endpoint/v1/artifact?download=1&path=${Uri.encodeQueryComponent(artifact['path'] as String)}',
        file.path,
        options: Options(
          followRedirects: false,
          headers: {'Authorization': 'Bearer $credential'},
        ),
      );
      if (epoch != _connectionEpoch) throw StateError('配对已改变，已丢弃旧连接下载');
      if (artifact['sha256'] != null &&
          (await sha256.bind(file.openRead()).first).toString() !=
              artifact['sha256']) {
        throw StateError('成果版本已改变或下载校验失败，请重新登记');
      }
      if (!mounted) return;
      AppToastMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存：${file.path}'),
          action: SnackBarAction(
            label: '导出',
            onPressed: () => SharePlus.instance.share(
              ShareParams(files: [XFile(file.path)]),
            ),
          ),
        ),
      );
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  Future<void> _resolveUnknown(Map<String, dynamic> task) async {
    final epoch = _connectionEpoch;
    final state = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('核验电脑上的实际结果'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('先检查文件、进程和外部系统。这里不重放未知操作；其他已批准的排队命令可能在核验后继续。'),
          ),
          for (final choice in const {
            'completed': '已核实完成',
            'failed': '已核实失败',
            'stopped': '已核实停止',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, choice.key),
              child: Text(choice.value),
            ),
        ],
      ),
    );
    if (!mounted || state == null || epoch != _connectionEpoch) return;
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const TextValueDialog(
        title: '登记核验依据',
        initialText: '',
        label: '检查了什么、结果是什么（必填）',
        minLines: 3,
        maxLength: 4000,
      ),
    );
    if (!mounted ||
        note == null ||
        note.trim().isEmpty ||
        epoch != _connectionEpoch) {
      return;
    }
    await _run(() async {
      await _request(
        'tasks/${task['id']}/resolve',
        body: {
          'version': task['version'] ?? task['updatedAt'],
          'state': state,
          'note': note,
        },
      );
      await _refresh();
    });
  }

  String _stateLabel(dynamic value) => switch (value) {
    'awaitingApproval' => '等待批准',
    'queued' => '排队',
    'running' => '执行中',
    'stopping' => '正在停止',
    'completed' => '已完成',
    'failed' => '失败',
    'stopped' => '已停止',
    'unknown' => '待核验',
    'waiting_budget' => '等待追加轮次',
    _ => '状态待更新',
  };
  @override
  void initState() {
    super.initState();
    _dio =
        widget.client ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
    unawaited(_restore());
  }

  Future<void> _restore() async {
    final pending = await _storage.read(key: 'remote_host_pending_by_host_v1');
    if (pending != null) {
      for (final entry in (jsonDecode(pending) as Map).entries) {
        _pendingByHost[entry.key as String] = Map<String, dynamic>.from(
          entry.value as Map,
        );
      }
    }
    final saved = await _storage.read(key: 'remote_host_computers_v1');
    if (saved != null) {
      _computers.addAll(
        (jsonDecode(saved) as List).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
    }
    final pair = await _storage.read(key: 'remote_host_pair_v1');
    if (!mounted) return;
    if (pair == null) {
      setState(() => _activatePending(_url.text.trim()));
      return;
    }
    final data = jsonDecode(pair) as Map;
    setState(() {
      _url.text = data['url'] as String;
      _token.text = data['token'] as String;
      _protectedTunnel = data['protectedTunnel'] == true;
      _activatePending(_url.text.trim());
    });
  }

  Future<dynamic> _request(
    String path, {
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async {
    final epoch = _connectionEpoch;
    final base = Uri.parse(_url.text.trim());
    final local = ['127.0.0.1', 'localhost', '::1'].contains(base.host);
    if (base.scheme != 'https' &&
        !(base.scheme == 'http' && (local || _protectedTunnel))) {
      throw StateError('使用 HTTPS 或先建立加密 VPN/SSH 隧道，再确认受保护连接');
    }
    if (base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment) {
      throw StateError('主机地址不能包含凭据、查询或片段');
    }
    final response = await _dio.request<dynamic>(
      '${_url.text.trim().replaceFirst(RegExp(r'/$'), '')}/v1/$path',
      data: body,
      cancelToken: cancelToken,
      options: Options(
        followRedirects: false,
        method: body == null ? 'GET' : 'POST',
        headers: {'Authorization': 'Bearer ${_token.text.trim()}'},
      ),
    );
    if (epoch != _connectionEpoch) throw StateError('配对已改变，忽略旧连接结果');
    return response.data;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (error is DioException && error.type == DioExceptionType.cancel) {
        return;
      }
      if (error is StateError && error.message.startsWith('配对已改变')) return;
      if (mounted) {
        setState(() => _error = _describeError(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describeError(Object error) {
    if (error is! DioException) return error.toString();
    if (error.response?.statusCode == 401) return '配对密钥无效或已过期，请从电脑重新获取';
    if (error.response?.statusCode == 429) return '配对验证失败次数过多，请稍后重连';
    final data = error.response?.data;
    if (data is Map && data['error'] is String) {
      final message = data['error'] as String;
      return '电脑未接受本次操作：${message.length > 800 ? message.substring(0, 800) : message}';
    }
    return '远程连接未完成（${error.response?.statusCode ?? error.type.name}），重连后查询原任务，不重复提交';
  }

  Future<void> _refresh() async {
    final epoch = _connectionEpoch;
    final cancel = CancelToken();
    _pollCancel = cancel;
    final data = await _request('tasks', cancelToken: cancel) as Map;
    final events =
        await _request('events?after=$_cursor', cancelToken: cancel) as Map;
    if (!mounted || epoch != _connectionEpoch) return;
    setState(() {
      final current = {for (final task in _tasks) task['id']: task};
      _tasks = (data['tasks'] as List).map((task) {
        final previous = current[task['id']];
        if (previous != null && !_notOlder(task, previous)) return previous;
        return task;
      }).toList();
      _allowedPolicies = (data['allowedPolicies'] as List? ?? ['request'])
          .whereType<String>()
          .where((value) => ['request', 'assisted', 'full'].contains(value))
          .toList();
      if (_allowedPolicies.isEmpty) _allowedPolicies = ['request'];
      if (!_allowedPolicies.contains(_policy)) _policy = 'request';
      _defaultRoundLimit = data['defaultRoundLimit'] as int? ?? 20;
      _roundCeiling = data['roundCeiling'] as int? ?? 200;
      _allowAutoBudget = data['allowAutoBudgetExtension'] == true;
      if (events['historyTruncated'] == true) _historyTruncated = true;
      for (final e in events['events'] as List) {
        _events.add(e);
        _cursor = e['cursor'] as int;
      }
      if (_events.length > 500) _events.removeRange(0, _events.length - 500);
    });
  }

  Future<void> _connect() async {
    final epoch = ++_connectionEpoch;
    _url.text = _normalizedAddress(_url.text);
    final pair = {
      'url': _url.text.trim(),
      'token': _token.text.trim(),
      'protectedTunnel': _protectedTunnel,
      'connectionId': const Uuid().v4(),
    };
    _timer?.cancel();
    _cursor = 0;
    _events.clear();
    _historyTruncated = false;
    _activatePending(_url.text.trim());
    await _refresh();
    if (!mounted || epoch != _connectionEpoch) return;
    if (_pendingSubmission == null && _roundLimit.text == '20') {
      _roundLimit.text = '$_defaultRoundLimit';
    }
    await _storage.write(key: 'remote_host_pair_v1', value: jsonEncode(pair));
    if (!mounted || epoch != _connectionEpoch) {
      await _discardPairAttempt(pair);
      return;
    }
    _computers.removeWhere((c) => c['url'] == _url.text.trim());
    _computers.add(pair);
    await _storage.write(
      key: 'remote_host_computers_v1',
      value: jsonEncode(_computers),
    );
    if (!mounted || epoch != _connectionEpoch) {
      await _discardPairAttempt(pair);
      return;
    }
    setState(() => _connected = true);
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_busy) unawaited(_run(_refresh));
    });
  }

  Future<void> _discardPairAttempt(Map<String, dynamic> attempt) async {
    try {
      final raw = await _storage.read(key: 'remote_host_pair_v1');
      if (raw != null &&
          (jsonDecode(raw) as Map)['connectionId'] == attempt['connectionId']) {
        await _storage.delete(key: 'remote_host_pair_v1');
      }
    } catch (_) {
      /* Do not delete a different/newer pairing on cleanup failure. */
    }
  }

  @override
  void dispose() {
    _connectionEpoch++;
    _timer?.cancel();
    _dio.close(force: true);
    _url.dispose();
    _token.dispose();
    _goal.dispose();
    _roundLimit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('远程任务'),
      actions: [
        IconButton(
          onPressed: _busy ? null : () => _run(_refresh),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_computers.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey('computer:${_url.text.trim()}'),
            isExpanded: true,
            initialValue: _computers.any((c) => c['url'] == _url.text.trim())
                ? _url.text.trim()
                : null,
            decoration: const InputDecoration(labelText: '已配对电脑'),
            items: [
              for (final computer in _computers)
                DropdownMenuItem(
                  value: computer['url'] as String,
                  child: Text(
                    computer['url'] as String,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    final computer = _computers.firstWhere(
                      (c) => c['url'] == value,
                    );
                    _timer?.cancel();
                    _connectionEpoch++;
                    setState(() {
                      _connected = false;
                      _tasks = [];
                      _events.clear();
                      _cursor = 0;
                      _url.text = computer['url'] as String;
                      _token.text = computer['token'] as String;
                      _protectedTunnel = computer['protectedTunnel'] == true;
                      _activatePending(_url.text.trim());
                    });
                  },
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  _timer?.cancel();
                  _connectionEpoch++;
                  setState(() {
                    _connected = false;
                    _url.clear();
                    _token.clear();
                    _tasks = [];
                    _events.clear();
                    _cursor = 0;
                  });
                },
          child: const Text('添加另一台电脑'),
        ),
        const Text(
          '电脑需独立启动执行宿主。手机断开后任务继续；电脑重启后的未确认操作不会自动重放。配对密钥只授权此宿主固定的工作目录，但命令使用电脑账号权限，不是沙箱。',
        ),
        if (_connected)
          RemoteAutomationPanel(
            request: _request,
            hostLabel: Uri.tryParse(_url.text.trim())?.host ?? '远程电脑',
            manualEventIds: _manualAutomationEvents.putIfAbsent(
              _deviceKey(_url.text.trim()),
              () => {},
            ),
          ),
        if (_connected) RemoteWorkspacePanel(request: _request),
        TextField(
          controller: _url,
          onChanged: (value) {
            if (!_busy) {
              _connectionEpoch++;
              setState(() => _activatePending(value.trim()));
            }
          },
          enabled: !_connected && !_busy,
          decoration: const InputDecoration(labelText: '电脑 HTTPS / 隧道地址'),
        ),
        TextField(
          controller: _token,
          onChanged: (_) {
            if (!_busy) {
              _connectionEpoch++;
              setState(() => _activatePending(_url.text.trim()));
            }
          },
          enabled: !_connected && !_busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '电脑 credential 文件中的配对密钥',
          ),
        ),
        CheckboxListTile(
          value: _protectedTunnel,
          onChanged: _connected || _busy
              ? null
              : (v) => setState(() => _protectedTunnel = v!),
          title: const Text('已通过自己的加密 VPN / SSH 隧道连接'),
          subtitle: const Text('普通局域网不等于加密连接。不要在不可信网络传输 HTTP 配对密钥。'),
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : () => _run(_connect),
              child: const Text('配对 / 重连'),
            ),
            TextButton(
              onPressed: () async {
                _connectionEpoch++;
                _timer?.cancel();
                await _storage.delete(key: 'remote_host_pair_v1');
                _computers.removeWhere((c) => c['url'] == _url.text.trim());
                await _storage.write(
                  key: 'remote_host_computers_v1',
                  value: jsonEncode(_computers),
                );
                if (mounted) {
                  setState(() {
                    _connected = false;
                    _token.clear();
                    _tasks = [];
                    _events.clear();
                    _cursor = 0;
                  });
                }
              },
              child: const Text('移除此配对（不停止电脑任务）'),
            ),
          ],
        ),
        if (_error != null)
          SelectableText(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_historyTruncated) const Text('较早日志已超出宿主保留窗口；当前任务状态仍来自持久记录。'),
        TextField(
          controller: _goal,
          enabled: !_busy,
          maxLines: 4,
          onChanged: (_) {
            if (!_busy) {
              final hadPending = _pendingSubmission != null;
              setState(() {
                _pendingId = null;
                _pendingSubmission = null;
              });
              if (hadPending) {
                _pendingByHost.remove(_deviceKey(_url.text.trim()));
                unawaited(_savePending().catchError((_) {}));
              }
            }
          },
          decoration: const InputDecoration(
            labelText: '电脑 Agent 目标（模型配置保留在电脑）',
          ),
        ),
        if (_connected) ...[
          DropdownButtonFormField<String>(
            key: ValueKey('task-policy:${_allowedPolicies.join(',')}'),
            isExpanded: true,
            initialValue: _policy,
            decoration: const InputDecoration(labelText: '此任务的命令权限'),
            items: [
              for (final mode in _allowedPolicies)
                DropdownMenuItem(value: mode, child: Text(_policyLabel(mode))),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _policy = value!),
          ),
          if (_policy == 'full')
            const Text('完全访问会自动执行此任务的命令，以电脑账号权限运行；工作目录不是沙箱。'),
          TextField(
            controller: _roundLimit,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: '模型轮次（1–$_roundCeiling）'),
          ),
          if (_allowAutoBudget)
            CheckboxListTile(
              value: _autoBudget,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _autoBudget = value!),
              title: const Text('允许有界续轮审查'),
              subtitle: const Text('达到轮次边界时，由审查模型建议有限追加；电脑上限和审查次数始终生效。'),
            ),
        ],
        if (_pendingSubmission != null && !_busy)
          const Text('有待核对的提交；重试沿用原目标、设备和权限快照，避免重复执行。修改目标会创建新任务。'),
        FilledButton(
          onPressed: !_connected || _busy || _goal.text.trim().isEmpty
              ? null
              : () => _run(() async {
                  final limit = int.tryParse(_roundLimit.text.trim());
                  if (_pendingSubmission == null &&
                      (limit == null || limit < 1 || limit > _roundCeiling)) {
                    throw StateError('模型轮次必须在 1 到 $_roundCeiling 之间');
                  }
                  _pendingId ??= const Uuid().v4();
                  _pendingSubmission ??= {
                    'id': _pendingId,
                    'goal': _goal.text,
                    'policy': _policy,
                    'roundLimit': limit,
                    'autoBudgetExtension': _autoBudget,
                  };
                  final endpoint = _deviceKey(_url.text.trim());
                  _pendingByHost[endpoint] = Map<String, dynamic>.from(
                    _pendingSubmission!,
                  );
                  await _savePending();
                  await _request('tasks', body: _pendingSubmission);
                  _pendingId = null;
                  _pendingSubmission = null;
                  _pendingByHost.remove(endpoint);
                  try {
                    await _savePending();
                  } catch (_) {}
                  _goal.clear();
                  await _refresh();
                }),
          child: const Text('提交目标'),
        ),
        for (final task in _tasks.reversed)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (task['kind'] == 'command') ...[
                    _monoBlock(task['command'] as String),
                    Text(_stateLabel(task['state'])),
                  ] else
                    SelectableText(
                      '${task['command']}\n${_stateLabel(task['state'])}',
                    ),
                  if (task['kind'] == 'agent')
                    Text(
                      '轮次 ${task['round'] ?? 0} / ${task['roundLimit'] ?? _defaultRoundLimit} · ${_policyLabel(task['policy'] as String? ?? 'request')}',
                    ),
                  if (task['state'] == 'waiting_budget')
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _extendBudget(task as Map),
                      child: const Text('追加轮次并继续'),
                    ),
                  if (task['approvalReview'] != null)
                    Text('辅助审查：${task['approvalReview']['reason']}'),
                  if (task['pendingCommand'] != null) ...[
                    const Text('待执行命令'),
                    _monoBlock(task['pendingCommand'] as String),
                  ],
                  if (task['result'] != null)
                    SelectableText(task['result'] as String),
                  if (task['state'] == 'unknown')
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _resolveUnknown(
                              Map<String, dynamic>.from(task as Map),
                            ),
                      child: const Text('核验未知结果'),
                    ),
                  for (final artifact in task['artifacts'] as List? ?? [])
                    TextButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(
                        '${artifact['path']} (${artifact['size']} B)',
                      ),
                      onPressed: _busy
                          ? null
                          : () => _run(() => _download(artifact as Map)),
                    ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (task['state'] == 'awaitingApproval')
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await _request(
                                    'tasks/${task['id']}/approve',
                                    body: {
                                      'version':
                                          task['version'] ?? task['updatedAt'],
                                    },
                                  );
                                  await _refresh();
                                }),
                          child: const Text('批准此步'),
                        ),
                      if ([
                        'running',
                        'awaitingApproval',
                        'queued',
                        'waiting_budget',
                      ].contains(task['state']))
                        TextButton.icon(
                          onPressed: _stopping.contains(task['id'])
                              ? null
                              : () => _stopTask(task as Map),
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: Text(
                            _stopping.contains(task['id']) ? '正在请求停止' : '停止',
                          ),
                        ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('日志与技术详情'),
                    children: [
                      SelectableText(
                        '任务标识：${task['id']}\n原始状态：${task['state']}',
                      ),
                      _monoBlock(
                        _events
                            .where((e) => e['taskId'] == task['id'])
                            .map(
                              (e) =>
                                  '${e['cursor']} ${e['kind']}: ${e['text'] ?? e['message'] ?? ''}',
                            )
                            .join('\n'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
