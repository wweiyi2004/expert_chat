import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'discovery.dart';
import 'protocol.dart';
import 'event_diff.dart';

class TuiBridgeServer {
  TuiBridgeServer({
    required this.backend,
    BridgeDiscovery? discovery,
    this.onStopped,
  }) : discovery =
           discovery ?? BridgeDiscovery(BridgeDiscovery.defaultDirectory());
  final BridgeBackend backend;
  final BridgeDiscovery discovery;
  final Future<void> Function()? onStopped;
  final serverId = const Uuid().v4();
  final _clients = <_Client>{};
  final _results =
      <String, ({String request, Future<Map<String, Object?>> response})>{};
  HttpServer? _server;
  String? _token;
  Timer? _updates;
  final _operations = <String, Future<void>>{};
  int? get port => _server?.port;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    try {
      _token = await discovery.publish(server.port);
    } catch (_) {
      await server.close(force: true);
      _server = null;
      rethrow;
    }
    server.listen(_upgrade);
    _updates = Timer.periodic(const Duration(milliseconds: 250), (_) {
      for (final client in _clients.toList()) {
        if (DateTime.now().difference(client.lastRequest).inSeconds > 45) {
          unawaited(client.socket.close(WebSocketStatus.goingAway));
        } else if (client.authenticated) {
          unawaited(_snapshot(client));
        }
      }
    });
  }

  Future<void> _upgrade(HttpRequest request) async {
    if (request.connectionInfo?.remoteAddress.isLoopback != true ||
        request.uri.path != '/tui' ||
        request.headers.value('origin') != null ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.pingInterval = const Duration(seconds: 15);
      final client = _Client(socket);
      _clients.add(client);
      final timeout = Timer(const Duration(seconds: 5), () {
        if (!client.authenticated) {
          unawaited(socket.close(WebSocketStatus.policyViolation));
        }
      });
      socket.listen(
        (raw) {
          // Parsing/authentication and enqueueing happen synchronously inside
          // _receive. Awaiting a long result here would block this same TUI's
          // heartbeat and urgent cancellation behind that result.
          unawaited(
            _receive(client, raw).catchError((Object _) {
              unawaited(socket.close(WebSocketStatus.invalidFramePayloadData));
            }),
          );
        },
        onDone: () {
          timeout.cancel();
          _clients.remove(client);
          if (backend case BridgeClientLifecycle lifecycle) {
            lifecycle.releaseClient(client.scope);
          }
        },
        onError: (Object _) {
          timeout.cancel();
          _clients.remove(client);
          if (backend case BridgeClientLifecycle lifecycle) {
            lifecycle.releaseClient(client.scope);
          }
        },
      );
    } catch (_) {
      /* Invalid upgrades never reach the backend. */
    }
  }

  Future<void> _receive(_Client client, Object? raw) async {
    if (client.socket.readyState != WebSocket.open) return;
    if (raw is! String || utf8.encode(raw).length > 1024 * 1024) {
      await client.socket.close(WebSocketStatus.messageTooBig);
      return;
    }
    String? id;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const BridgeFailure('invalid_request', '请求必须是对象');
      }
      final request = Map<String, dynamic>.from(decoded);
      id = requiredString(request, 'id');
      if (id.length > 200 || request['v'] != 1) {
        throw const BridgeFailure('version', '协议版本不兼容');
      }
      final method = requiredString(request, 'method');
      final params = Map<String, dynamic>.from(request['params'] as Map? ?? {});
      client.lastRequest = DateTime.now();
      if (!client.authenticated) {
        if (method != 'hello' ||
            params['protocol'] != 1 ||
            !_tokenEquals(params['token'])) {
          _send(
            client,
            _error(id, const BridgeFailure('unauthorized', '认证失败')),
          );
          await client.socket.close(WebSocketStatus.policyViolation);
          return;
        }
        client.clientId = requiredString(params, 'client_id');
        if (client.clientId.length > 200) {
          throw const BridgeFailure('invalid_params', 'client_id 过长');
        }
        client.authenticated = true;
        _send(client, {
          'v': 1,
          'id': id,
          'ok': true,
          'result': {
            'protocol': 1,
            'server_id': serverId,
            'pid': pid,
            'capabilities': [
              'ping',
              'snapshot.get',
              'session.open',
              'bridge.stop',
              ...backend.capabilities,
            ],
          },
        });
        return;
      }
      if (method == 'hello') {
        throw const BridgeFailure('invalid_request', '已完成握手');
      }
      final cacheKey = jsonEncode([client.clientId, id]);
      final fingerprint = jsonEncode([method, params]);
      final previous = _results[cacheKey];
      if (previous != null && previous.request != fingerprint) {
        throw const BridgeFailure('conflict', '请求 id 已用于其他操作');
      }
      // Scope is server-issued, never trust a client-provided attachment scope.
      final openRevision = method == 'session.open'
          ? client.openRequests.putIfAbsent(
              cacheKey,
              () => ++client.openRevision,
            )
          : null;
      final result =
          previous?.response ??
          _serialized(method, params, () async {
            try {
              final Map<String, Object?> data;
              switch (method) {
                case 'ping':
                  data = {'time': DateTime.now().toUtc().toIso8601String()};
                case 'snapshot.get':
                  data = await backend.snapshot(
                    params['session_id'] as String?,
                  );
                case 'session.open':
                  final session = requiredString(params, 'session_id');
                  data = await backend.snapshot(session);
                case 'bridge.stop':
                  data = {'accepted': true};
                default:
                  data = await backend.invoke(method, {
                    ...params,
                    '_bridge_client_scope': client.scope,
                  });
              }
              return {'v': 1, 'id': id, 'ok': true, 'result': data};
            } on BridgeFailure catch (error) {
              return _error(id!, error);
            } catch (_) {
              return _error(
                id!,
                const BridgeFailure(
                  'operation_failed',
                  '操作失败，请检查参数、权限与 GUI 中的任务状态',
                ),
              );
            }
          });
      if (previous == null) {
        _results[cacheKey] = (request: fingerprint, response: result);
        while (_results.length > 512) {
          _results.remove(_results.keys.first);
        }
      }
      var response = await result;
      if (method == 'session.open' &&
          response['ok'] == true &&
          openRevision != client.openRevision) {
        response = _error(
          id,
          const BridgeFailure('superseded', '已被更新的会话打开请求取代'),
        );
        _results[cacheKey] = (
          request: fingerprint,
          response: Future.value(response),
        );
      }
      if (method == 'session.open' &&
          response['ok'] == true &&
          openRevision == client.openRevision) {
        client.session = params['session_id'] as String;
        client.previousSnapshot = null;
        client.lastSnapshot = '';
      }
      _send(client, response);
      if (method == 'bridge.stop') unawaited(stop());
    } on BridgeFailure catch (error) {
      _send(client, _error(id ?? '', error));
    } catch (_) {
      _send(
        client,
        _error(id ?? '', const BridgeFailure('invalid_request', '请求格式无效')),
      );
    }
  }

  Future<T> _serialized<T>(
    String method,
    Map<String, dynamic> params,
    Future<T> Function() operation,
  ) {
    // Reads and urgent cancellation must not wait behind unrelated I/O. The
    // backend independently checks object scope and current execution state.
    const independent = {
      'ping',
      'snapshot.get',
      'session.open',
      'session.list',
      'models.list',
      'workspace.list',
      'workspace.prepare',
      'changes.list',
      'changes.diff',
      'agents.list',
      'files.list',
      'task.stop',
      'agent.stop',
      'bridge.stop',
      'attachment.cancel',
    };
    if (independent.contains(method)) return operation();
    final key = params['session_id'] is String
        ? params['session_id'] as String
        : '__global__';
    final result = (_operations[key] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _operations[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_operations[key], tail)) _operations.remove(key);
      }),
    );
    return result;
  }

  bool _tokenEquals(Object? token) {
    if (token is! String || _token == null) return false;
    var difference = token.length ^ _token!.length;
    for (var i = 0; i < _token!.length; i++) {
      difference |=
          _token!.codeUnitAt(i) ^ (i < token.length ? token.codeUnitAt(i) : 0);
    }
    return difference == 0;
  }

  Map<String, Object?> _error(String id, BridgeFailure error) => {
    'v': 1,
    'id': id,
    'ok': false,
    'error': {'code': error.code, 'message': error.message, 'retryable': false},
  };
  bool _send(_Client client, Map<String, Object?> value) {
    final encoded = jsonEncode(value);
    if (utf8.encode(encoded).length > 8 * 1024 * 1024) {
      if (value['type'] == 'event') {
        _snapshotError(client, 'too_large', '快照超过 8 MiB，请在 GUI 查看完整记录');
      } else if (client.socket.readyState == WebSocket.open) {
        client.socket.add(
          jsonEncode(
            _error(
              value['id'] as String? ?? '',
              const BridgeFailure('too_large', '快照超过 8 MiB，请在 GUI 查看完整记录'),
            ),
          ),
        );
      }
      return false;
    }
    if (client.socket.readyState != WebSocket.open) return false;
    client.socket.add(encoded);
    return true;
  }

  void _snapshotError(_Client client, String code, String message) {
    if (client.snapshotError == code) return;
    client.snapshotError = code;
    _send(client, {
      'v': 1,
      'type': 'event',
      'seq': ++client.seq,
      'session_id': client.session,
      'event': 'request.error',
      'data': {
        'code': code,
        'message': message,
        'retryable': true,
        'scope': 'snapshot',
      },
    });
  }

  Future<void> _snapshot(_Client client) async {
    if (client.snapshotBusy) return;
    client.snapshotBusy = true;
    try {
      final session = client.session;
      final snapshot = await backend.snapshot(session);
      if (client.session != session || !_clients.contains(client)) return;
      final signature = jsonEncode(snapshot);
      if (signature != client.lastSnapshot || client.snapshotError != null) {
        if (utf8.encode(signature).length > 8 * 1024 * 1024 - 512) {
          _snapshotError(client, 'too_large', '快照超过 8 MiB，请在 GUI 查看完整记录');
          return;
        }
        if (client.previousSnapshot case final previous?) {
          for (final event in bridgeSnapshotEvents(previous, snapshot)) {
            _send(client, {
              'v': 1,
              'type': 'event',
              'seq': ++client.seq,
              'session_id': session,
              'event': event.event,
              'data': event.data,
            });
          }
        }
        final sent = _send(client, {
          'v': 1,
          'type': 'event',
          'seq': ++client.seq,
          'session_id': session,
          'event': 'snapshot',
          'data': snapshot,
        });
        if (sent) {
          client.previousSnapshot = snapshot;
          client.lastSnapshot = signature;
          client.snapshotError = null;
        }
      }
    } catch (_) {
      _snapshotError(client, 'snapshot_failed', '状态刷新失败，当前显示可能已过期；正在重试。');
    } finally {
      client.snapshotBusy = false;
    }
  }

  Future<void> stop() async {
    _updates?.cancel();
    _updates = null;
    for (final client in _clients.toList()) {
      await client.socket.close(WebSocketStatus.goingAway);
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    await discovery.remove();
    _token = null;
    await onStopped?.call();
  }
}

class _Client {
  _Client(this.socket);
  final WebSocket socket;
  final String scope = const Uuid().v4();
  bool authenticated = false, snapshotBusy = false;
  String clientId = '', lastSnapshot = '';
  String? session, snapshotError;
  int seq = 0, openRevision = 0;
  final openRequests = <String, int>{};
  DateTime lastRequest = DateTime.now();
  Map<String, Object?>? previousSnapshot;
}
