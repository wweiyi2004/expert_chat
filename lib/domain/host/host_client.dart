import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../features/tui_bridge/discovery.dart';
import 'wire_models.dart';
import 'chat_projection.dart';

class HostRpcException implements Exception {
  const HostRpcException(
    this.code,
    this.message, {
    this.outcomeUnknown = false,
  });
  final String code, message;
  final bool outcomeUnknown;
  @override
  String toString() => message;
}

class HostClient {
  HostClient({
    required this.discoveryDirectory,
    required this.hostExecutable,
    this.dataDirectory,
  });
  static HostClient? current;
  final Directory discoveryDirectory;
  final String hostExecutable;
  final String? dataDirectory;
  final String clientId = const Uuid().v4();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Stream<Map<String, dynamic>> get updates => _updates.stream;
  Map<String, dynamic> state = {};
  WebSocket? _socket;
  Timer? _heartbeat;
  bool _closed = false, _refreshAgain = false;
  int _settingsRevision = -1;
  Map<String, dynamic> _runtimeVersions = {};
  int _revision = -1, _selectionRevision = 0;
  int _chatCursor = 0;
  String? selectedSession;
  String? _token, _guiToken;
  int? _port;
  Future<void>? _connecting;
  Future<void>? _refreshTask;
  bool _forceRefresh = false, _reconnectScheduled = false;
  bool get connected => _socket?.readyState == WebSocket.open;
  void reportError(String message) {
    if (!_closed) _updates.add({'operation_error': message});
  }

  static Future<HostClient> attachDefault() async {
    final data = Platform.environment['EXPERT_HOST_DATA_DIR'];
    final discovery = Platform.environment['EXPERT_HOST_DISCOVERY'];
    if (data != null && !p.isAbsolute(data) ||
        discovery != null && !p.isAbsolute(discovery)) {
      throw const HostRpcException('invalid_path', '独立资料和发现目录必须使用绝对路径');
    }
    final client = HostClient(
      discoveryDirectory: discovery != null
          ? Directory(discovery)
          : data != null
          ? Directory(p.join(data, 'host', 'discovery'))
          : BridgeDiscovery.defaultDirectory(),
      dataDirectory: data,
      hostExecutable:
          Platform.environment['EXPERT_CHAT_HOST'] ??
          p.join(
            p.dirname(Platform.resolvedExecutable),
            'host',
            'bin',
            'expert-host.exe',
          ),
    );
    await client.connect(startIfNeeded: true);
    current = client;
    await client.refresh(force: true);
    return client;
  }

  Future<void> connect({bool startIfNeeded = false}) => _connecting ??=
      _connect(startIfNeeded).whenComplete(() => _connecting = null);
  Future<void> _connect(bool startIfNeeded) async {
    if (_closed) throw const HostRpcException('closed', '客户端连接已关闭');
    if (connected) return;
    final file = File(p.join(discoveryDirectory.path, 'bridge.json'));
    bool started = false;
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (!_closed && DateTime.now().isBefore(deadline)) {
      WebSocket? attempt;
      try {
        final info = wireMap(jsonDecode(await file.readAsString()));
        final gui = wireMap(
          jsonDecode(
            await File(
              p.join(discoveryDirectory.path, 'gui.json'),
            ).readAsString(),
          ),
        );
        if (info['pid'] != gui['pid']) throw const FormatException('发现信息版本不一致');
        _port = info['port'] as int;
        _token = info['token'] as String;
        _guiToken = gui['token'] as String;
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$_port/tui',
        ).timeout(const Duration(seconds: 2));
        attempt = socket;
        _socket = socket;
        socket.listen(
          _receive,
          onDone: () {
            if (identical(_socket, socket)) _disconnected();
          },
          onError: (Object _) {
            if (identical(_socket, socket)) _disconnected();
          },
        );
        final hello = await invoke('hello', {
          'protocol': 1,
          'token': _token,
          'client_id': clientId,
          'features': ['window-lifecycle.v1'],
          'role': 'gui',
          'gui_token': _guiToken,
        }, timeout: const Duration(seconds: 5));
        if (hello['execution_host'] != 'dart' ||
            hello['host_version'] != '1' ||
            hello['pid'] != info['pid']) {
          await socket.close();
          throw const HostRpcException(
            'incompatible',
            '当前后台不是兼容的独立宿主，请结束旧任务并退出旧版。',
          );
        }
        _heartbeat?.cancel();
        _settingsRevision = -1;
        _revision = -1;
        _chatCursor = 0;
        _runtimeVersions = {};
        _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
          if (connected) {
            unawaited(
              invoke('ping', {}).catchError((Object _) => <String, dynamic>{}),
            );
          }
        });
        return;
      } on HostRpcException {
        if (identical(_socket, attempt)) _socket = null;
        await attempt?.close();
        rethrow;
      } catch (_) {
        if (identical(_socket, attempt)) _socket = null;
        await attempt?.close();
        if (startIfNeeded && !started) {
          if (!p.isAbsolute(hostExecutable) ||
              !await File(hostExecutable).exists()) {
            throw const HostRpcException(
              'missing_host',
              '此安装缺少独立执行宿主，请使用完整发行包。',
            );
          }
          await Process.start(hostExecutable, [
            '--gui-client-pid',
            '$pid',
            '--discovery-dir',
            discoveryDirectory.path,
            if (dataDirectory != null) ...['--data-dir', dataDirectory!],
          ], mode: ProcessStartMode.detached);
          started = true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw const HostRpcException('unavailable', '无法连接独立宿主；旧任务未被接管或重放。');
  }

  void _receive(dynamic raw) {
    if (raw is! String) return;
    try {
      final message = wireMap(jsonDecode(raw));
      final id = message['id'] as String?;
      if (id != null && _pending.containsKey(id)) {
        final pending = _pending.remove(id)!;
        if (message['ok'] == true) {
          pending.complete(wireMap(message['result']));
        } else {
          final error = wireMap(message['error']);
          pending.completeError(
            HostRpcException(
              error['code'] as String? ?? 'failed',
              error['message'] as String? ?? '操作失败',
              outcomeUnknown: const {
                'operation_failed',
                'unknown_result',
              }.contains(error['code']),
            ),
          );
        }
      } else if (message['event'] == 'host.changed') {
        unawaited(
          refresh().catchError((Object error) {
            _updates.add({'connection_error': error.toString()});
          }),
        );
      }
    } catch (_) {
      _disconnected();
    }
  }

  void _disconnected() {
    _socket = null;
    _heartbeat?.cancel();
    for (final request in _pending.values) {
      if (!request.isCompleted) {
        request.completeError(
          const HostRpcException(
            'disconnected',
            '连接中断，操作结果未知；未自动重发。',
            outcomeUnknown: true,
          ),
        );
      }
    }
    _pending.clear();
    if (!_closed && !_reconnectScheduled) {
      _reconnectScheduled = true;
      _updates.add({'connection_error': '与宿主断开，当前显示旧状态'});
      unawaited(
        Future<void>.delayed(const Duration(seconds: 1), () async {
          if (_closed) return;
          try {
            await connect();
            await refresh(force: true);
            _reconnectScheduled = false;
          } catch (_) {
            _reconnectScheduled = false;
            if (!_closed) _disconnected();
          }
        }),
      );
    }
  }

  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
    String? requestId,
  }) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const HostRpcException('not_sent', '宿主未连接，本次操作尚未发送');
    }
    final id = requestId ?? const Uuid().v4();
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    socket.add(
      jsonEncode({'v': 1, 'id': id, 'method': method, 'params': params}),
    );
    try {
      return await reply.future.timeout(
        timeout,
        onTimeout: () => throw const HostRpcException(
          'timeout',
          '尚未收到操作回执，结果未知；请核对当前状态。',
          outcomeUnknown: true,
        ),
      );
    } finally {
      _pending.remove(id);
    }
  }

  Future<Object?> call(
    String service,
    String operation,
    Map<String, Object?> args, {
    String? session,
  }) async {
    final response = await invoke('$service.call', {
      'operation': operation,
      'arguments': args,
      'session_id': session,
    });
    final job = response['job_id'] as String?;
    if (job == null) return response['value'];
    while (!_closed) {
      final result = await invoke('host.operation', {'job_id': job});
      if (result['done'] == true) {
        if (result['error'] != null) {
          final error = wireMap(result['error']);
          throw HostRpcException(
            error['code'] as String? ?? 'failed',
            error['message'] as String? ?? '操作失败',
            outcomeUnknown: const {
              'operation_failed',
              'unknown_result',
            }.contains(error['code']),
          );
        }
        await refresh(force: true);
        return result['value'];
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const HostRpcException(
      'closed',
      '客户端已退出；后台任务仍由宿主管理',
      outcomeUnknown: true,
    );
  }

  Future<void> select(String? id) async {
    selectedSession = id;
    _selectionRevision++;
    _revision = -1;
    if (id != null) {
      await invoke('host.loadSession', {
        'session_id': id,
        'view': true,
        'selection_revision': _selectionRevision,
      });
    }
    await refresh(force: true);
  }

  Future<void> refresh({bool force = false}) {
    _forceRefresh = _forceRefresh || force;
    if (_refreshTask != null) {
      _refreshAgain = true;
      return _refreshTask!;
    }
    return _refreshTask = _refresh().whenComplete(() => _refreshTask = null);
  }

  Future<void> _refresh() async {
    if (!connected) return;
    try {
      do {
        _refreshAgain = false;
        final selection = _selectionRevision;
        final force = _forceRefresh;
        _forceRefresh = false;
        final result = await invoke('host.gui.snapshot', {
          'known_revision': force ? -1 : _revision,
          'known_settings_revision': _settingsRevision,
          'known_runtime_versions': _runtimeVersions,
          'session_id': selectedSession,
          'chat_cursor': _chatCursor,
        });
        if (selection != _selectionRevision) {
          _refreshAgain = true;
          continue;
        }
        if (result['unchanged'] != true) {
          if (result['chat_patch'] != null) {
            final patch = wireMap(result['chat_patch']);
            if (patch['reset'] != true && patch['base_cursor'] != _chatCursor) {
              _chatCursor = 0;
              _revision = -1;
              _forceRefresh = true;
              _refreshAgain = true;
              continue;
            }
            result['chat'] = applyChatProjection(
              state['chat'] == null ? null : wireMap(state['chat']),
              patch,
            );
            _chatCursor = patch['cursor'] as int;
            result.remove('chat_patch');
          }
          if (result['runtime'] != null) {
            result['runtime'] = {
              ...wireMap(state['runtime']),
              ...wireMap(result['runtime']),
            };
          }
          _runtimeVersions = wireMap(result['runtime_versions']);
          state = {...state, ...result};
          _revision = result['revision'] as int? ?? _revision;
          _settingsRevision =
              result['settings_revision'] as int? ?? _settingsRevision;
          _updates.add(state);
        }
      } while (_refreshAgain && connected);
    } finally {
      /* Pending refresh callers observe the same completed task. */
    }
  }

  Future<WebSocket> openDatabase() async {
    if (!connected) throw const HostRpcException('disconnected', '数据库连接不可用');
    return WebSocket.connect(
      'ws://127.0.0.1:$_port/database',
      headers: {HttpHeaders.authorizationHeader: 'Bearer $_guiToken'},
    ).timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    if (connected && !_closed) {
      try {
        await invoke('window.close', {}, timeout: const Duration(seconds: 3));
      } catch (_) {}
    }
    _closed = true;
    _heartbeat?.cancel();
    await _socket?.close();
    _disconnected();
    await _updates.close();
    if (identical(current, this)) current = null;
  }
}
