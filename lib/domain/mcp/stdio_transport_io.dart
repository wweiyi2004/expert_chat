import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import '../../data/mcp_process_config.dart';
import 'playwright_process_io.dart';

class StdioTransportException implements Exception {
  const StdioTransportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One owned subprocess and one ordered MCP stream. A lost response never
/// triggers automatic tool replay. Cancellation retires the whole connection.
class StdioTransport {
  StdioTransport(this.config);
  final McpProcessConfig config;
  Process? _process;
  Future<void>? _starting;
  Future<void>? _closing;
  bool _closed = false;
  bool _initialized = false;
  int _nextId = 0;
  String _buffer = '';
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  StreamSubscription<String>? _stdout;
  StreamSubscription<List<int>>? _stderr;
  Map<String, dynamic> serverInfo = {};
  static const maxMessageChars = 16 * 1024 * 1024;
  bool get isAlive => !_closed && _process != null;
  bool get isClosed => _closed;

  Future<void> initialize({
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (_initialized && isAlive) return Future.value();
    return _starting ??= _initialize(cancelToken, timeout);
  }

  Future<void> _initialize(CancelToken? cancel, Duration timeout) async {
    if (_closed || cancel?.isCancelled == true) {
      throw const StdioTransportException('MCP 启动已取消');
    }
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      throw const StdioTransportException('本地 MCP 仅支持桌面平台');
    }
    try {
      final launch = await prepareMcpProcess(config);
      final started = await Process.start(
        launch.command,
        launch.arguments,
        workingDirectory: launch.directory,
        environment: launch.environment,
        includeParentEnvironment: launch.environment == null,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      _process = started;
      if (_closed || cancel?.isCancelled == true) {
        started.kill();
        throw const StdioTransportException('MCP 启动已取消');
      }
      _stdout = started.stdout
          .transform(utf8.decoder)
          .listen(
            _read,
            onError: (_) => _fail('MCP 输出不是有效的 UTF-8'),
            onDone: () => _fail('本地 MCP 连接已关闭；执行结果可能未确认，请重新观察后继续'),
          );
      // Drain diagnostics without storing credentials or arbitrary server output.
      _stderr = started.stderr.listen((_) {});
      unawaited(started.exitCode.then((_) => _fail('本地 MCP 进程已退出；请重新连接')));
      final reply = await request(
        'initialize',
        {
          'protocolVersion': '2025-11-25',
          'capabilities': <String, dynamic>{},
          'clientInfo': {'name': 'expert-chat', 'version': '3.6.0'},
        },
        cancelToken: cancel,
        timeout: timeout,
      );
      if (!{
        '2024-11-05',
        '2025-03-26',
        '2025-06-18',
        '2025-11-25',
      }.contains(reply['protocolVersion'])) {
        throw const StdioTransportException('本地 MCP 协议版本不受支持');
      }
      serverInfo = reply['serverInfo'] is Map
          ? Map<String, dynamic>.from(reply['serverInfo'] as Map)
          : {};
      _write({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      _initialized = true;
    } catch (error) {
      await close();
      if (error is StdioTransportException) rethrow;
      if (error is StateError) {
        throw StdioTransportException(error.message.toString());
      }
      throw const StdioTransportException('无法启动本地 MCP：请检查程序路径、参数及运行环境');
    }
  }

  void _read(String chunk) {
    _buffer += chunk;
    if (_buffer.length > maxMessageChars) {
      _fail('MCP 单条响应超过大小上限');
      return;
    }
    while (_buffer.contains('\n')) {
      final end = _buffer.indexOf('\n');
      final line = _buffer.substring(0, end).trim();
      _buffer = _buffer.substring(end + 1);
      if (line.isEmpty) continue;
      try {
        final message = jsonDecode(line);
        if (message is! Map || message['jsonrpc'] != '2.0') {
          throw const FormatException();
        }
        if (message['method'] != null) {
          if (message['id'] != null) {
            _write({
              'jsonrpc': '2.0',
              'id': message['id'],
              if (message['method'] == 'ping')
                'result': <String, dynamic>{}
              else
                'error': {
                  'code': -32601,
                  'message': 'Client method not supported',
                },
            });
          }
          continue;
        }
        final pending = _pending[message['id']];
        if (pending == null || pending.isCompleted) continue;
        if (message['error'] is Map) {
          pending.completeError(
            const StdioTransportException('MCP 服务拒绝了请求；请检查工具参数与协议'),
          );
        } else if (message['result'] is Map) {
          pending.complete(Map<String, dynamic>.from(message['result'] as Map));
        } else {
          pending.completeError(const StdioTransportException('MCP 返回无效结果'));
        }
      } catch (_) {
        _fail('MCP 标准输出包含无效 JSON-RPC 数据');
      }
    }
  }

  void _write(Map<String, dynamic> value) {
    if (!isAlive) throw const StdioTransportException('本地 MCP 尚未连接');
    _process!.stdin.writeln(jsonEncode(value));
  }

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    CancelToken? cancelToken,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (cancelToken?.isCancelled == true) {
      throw const StdioTransportException('MCP 请求已取消');
    }
    final id = ++_nextId;
    final completion = Completer<Map<String, dynamic>>();
    _pending[id] = completion;
    var done = false;
    final timer = Timer(timeout, () => _fail('MCP 请求超时；未自动重试，请核验目标状态'));
    cancelToken?.whenCancel.then((_) {
      if (done) return;
      if (isAlive) {
        try {
          _write({
            'jsonrpc': '2.0',
            'method': 'notifications/cancelled',
            'params': {'requestId': id, 'reason': 'User stopped'},
          });
        } catch (_) {}
      }
      _fail('MCP 请求已取消；已发生的操作无法撤销');
    });
    try {
      _write({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
      return await completion.future;
    } finally {
      done = true;
      timer.cancel();
      _pending.remove(id);
    }
  }

  void _fail(String message) {
    for (final value in _pending.values) {
      if (!value.isCompleted) {
        value.completeError(StdioTransportException(message));
      }
    }
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _initialized = false;
    for (final value in _pending.values) {
      if (!value.isCompleted) {
        value.completeError(const StdioTransportException('本地 MCP 已断开'));
      }
    }
    final process = _process;
    if (process != null) {
      try {
        await process.stdin.close().timeout(const Duration(milliseconds: 300));
      } catch (_) {}
      try {
        await process.exitCode.timeout(const Duration(milliseconds: 500));
      } catch (_) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _process = null;
  }
}
