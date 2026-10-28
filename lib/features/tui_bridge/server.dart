import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'discovery.dart';
import 'protocol.dart';
import 'event_diff.dart';
import 'snapshot_patch.dart';

abstract interface class BridgeDatabaseEndpoint {
  Future<void> attachDatabase(WebSocket socket);
}

class TuiBridgeServer {
  TuiBridgeServer({
    required this.backend,
    BridgeDiscovery? discovery,
    this.onStopped,
    this.privilegedToken,
  }) : discovery =
           discovery ?? BridgeDiscovery(BridgeDiscovery.defaultDirectory());
  final BridgeBackend backend;
  final BridgeDiscovery discovery;
  final Future<void> Function()? onStopped;
  final String? privilegedToken;
  final serverId = const Uuid().v4();
  final _clients = <_Client>{};
  final _clientCleanups = <Future<void>>{};
  final _windowReleases = <String, _WindowRelease>{};
  bool _stopping = false;
  final _results =
      <String, ({String request, Future<Map<String, Object?>> response})>{};
  HttpServer? _server;
  String? _token;
  Timer? _updates;
  final _operations = <String, Future<void>>{};
  int? get port => _server?.port;
  int get clientCount => _clients.where((c) => c.authenticated).length;

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
    _updates = Timer.periodic(
      Duration(milliseconds: backend is PersistentBridgeHost ? 100 : 250),
      (_) {
        for (final client in _clients.toList()) {
          if (DateTime.now().difference(client.lastRequest).inSeconds > 45) {
            unawaited(client.socket.close(WebSocketStatus.goingAway));
          } else if (client.authenticated) {
            unawaited(_snapshot(client));
          }
        }
      },
    );
  }

  Future<void> _upgrade(HttpRequest request) async {
    if (request.connectionInfo?.remoteAddress.isLoopback == true &&
        request.headers.value('origin') == null &&
        request.uri.path == '/database' &&
        backend is BridgeDatabaseEndpoint &&
        privilegedToken != null &&
        _constantEquals(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer $privilegedToken',
        ) &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      final socket = await WebSocketTransformer.upgrade(request);
      unawaited(
        (backend as BridgeDatabaseEndpoint).attachDatabase(socket).catchError((
          Object _,
        ) async {
          await socket.close(WebSocketStatus.internalServerError);
        }),
      );
      return;
    }
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
          unawaited(_releaseClient(client));
        },
        onError: (Object _) {
          timeout.cancel();
          _clients.remove(client);
          unawaited(_releaseClient(client));
        },
      );
    } catch (_) {
      /* Invalid upgrades never reach the backend. */
    }
  }

  Future<void> _receive(_Client client, Object? raw) async {
    if (client.socket.readyState != WebSocket.open) return;
    if (raw is! String ||
        utf8.encode(raw).length > (client.privileged ? 64 : 1) * 1024 * 1024) {
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
        if (params['role'] == 'gui') {
          if (privilegedToken == null ||
              !_constantEquals(params['gui_token'], privilegedToken!)) {
            throw const BridgeFailure('unauthorized', '图形客户端授权无效');
          }
          client.privileged = true;
        }
        client.windowScoped = (params['features'] as List? ?? []).contains(
          'window-lifecycle.v1',
        );
        final pending = _windowReleases[client.clientId];
        if (client.windowScoped &&
            pending != null &&
            pending.client.privileged == client.privileged) {
          _windowReleases.remove(client.clientId);
          pending.timer?.cancel();
          client.scope = pending.client.scope;
          if (!pending.done.isCompleted) pending.done.complete();
        }
        if (client.privileged) {
          if (backend case BridgeGuiLifecycle lifecycle) {
            lifecycle.registerGuiClient(client.scope);
          }
        }
        if (client.windowScoped) {
          if (backend case WindowTaskLifecycle lifecycle) {
            lifecycle.registerWindowClient(client.scope);
          }
        }
        client.authenticated = true;
        client.patchSnapshots = (params['features'] as List? ?? []).contains(
          'snapshot.patch',
        );
        _send(client, {
          'v': 1,
          'id': id,
          'ok': true,
          'result': {
            'protocol': 1,
            'server_id': serverId,
            'pid': pid,
            'execution_host': backend is PersistentBridgeHost
                ? 'dart'
                : 'flutter',
            if (backend case PersistentBridgeHost host)
              'host_version': host.hostVersion,
            'capabilities': [
              'ping',
              'snapshot.get',
              'session.open',
              'bridge.stop',
              'window.close',
              if (backend is WindowTaskLifecycle) 'window-lifecycle.v1',
              ...backend.capabilities,
            ],
          },
        });
        return;
      }
      if (method == 'hello') {
        throw const BridgeFailure('invalid_request', '已完成握手');
      }
      if (method == 'window.close') {
        client.windowClosing = true;
        await _releaseClient(client, immediate: true);
        _send(client, {
          'v': 1,
          'id': id,
          'ok': true,
          'result': {'accepted': true},
        });
        unawaited(client.socket.close(WebSocketStatus.normalClosure));
        return;
      }
      if (client.windowClosing) {
        throw const BridgeFailure('closing', '窗口正在退出');
      }
      if (backend case PrivilegedBridgeBackend privileged) {
        if (privileged.isPrivilegedMethod(method) && !client.privileged) {
          throw const BridgeFailure('forbidden', '此操作仅供受信任的本机图形客户端');
        }
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
                  data = await _clientSnapshot(
                    client,
                    params['session_id'] as String?,
                  );
                case 'session.open':
                  final session = requiredString(params, 'session_id');
                  data = await _clientSnapshot(client, session);
                case 'bridge.stop':
                  data = {'accepted': true};
                default:
                  data = await backend.invoke(method, {
                    ...params,
                    '_bridge_client_scope': client.scope,
                    '_bridge_request_id': cacheKey,
                  });
              }
              return {'v': 1, 'id': id, 'ok': true, 'result': data};
            } on BridgeFailure catch (error) {
              return _error(id!, error);
            } catch (_) {
              return _error(
                id!,
                const BridgeFailure('operation_failed', '操作未完成，请核对当前会话或设置后重试'),
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
        final selectedSession = params['session_id'] as String;
        if (backend case BridgeClientLifecycle lifecycle) {
          await lifecycle.selectClientSession(client.scope, selectedSession);
        }
        if (openRevision != client.openRevision) {
          response = _error(
            id,
            const BridgeFailure('superseded', '已被更新的会话打开请求取代'),
          );
          _results[cacheKey] = (
            request: fingerprint,
            response: Future.value(response),
          );
        } else {
          client.session = selectedSession;
          client.previousSnapshot = null;
          client.lastSnapshot = '';
        }
      }
      _send(client, response);
      if (method == 'snapshot.get' &&
          response['ok'] == true &&
          client.patchSnapshots) {
        // Reset after sending the query response. An in-flight timer must not
        // publish a baseline that the later response would immediately replace.
        client.previousSnapshot = null;
        client.lastSnapshot = '';
      }
      if (method == 'bridge.stop') {
        if (backend is PersistentBridgeHost) {
          unawaited(client.socket.close(WebSocketStatus.normalClosure));
        } else {
          unawaited(stop());
        }
      }
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
      'provider.login.list',
      'provider.login.account',
      'provider.login.usage',
      'provider.login.status',
      'provider.login.cancel',
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
      'host.loadSession',
      'host.gui.snapshot',
      'host.gui.actionResult',
      'host.operation',
      'host.llm.cancel',
      'host.llm.poll',
      'host.ssh.poll',
      'host.ssh.cancel',
      'host.ssh.resize',
      'host.ssh.control',
      'plan.get',
      'checkpoint.list',
      'checkpoint.preview',
      'plan.approve',
      'plan.comment',
      'plan.cancel',
    };
    if (independent.contains(method) ||
        (method == 'terminal.query' &&
            const {
              'ssh.status',
              'shell.status',
              'shell.latest',
            }.contains(params['topic'])) ||
        (method == 'terminal.action' &&
            const {
              'ssh.trust',
              'ssh.cancel',
              'shell.cancel',
            }.contains(params['action']))) {
      return operation();
    }
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
    return _token != null && _constantEquals(token, _token!);
  }

  bool _constantEquals(Object? token, String expected) {
    if (token is! String) return false;
    var difference = token.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      difference |=
          expected.codeUnitAt(i) ^ (i < token.length ? token.codeUnitAt(i) : 0);
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
    if (utf8.encode(encoded).length >
        (client.privileged ? 64 : 8) * 1024 * 1024) {
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

  Future<Map<String, Object?>> _clientSnapshot(
    _Client client,
    String? session,
  ) => client.windowScoped && backend is WindowTaskLifecycle
      ? (backend as WindowTaskLifecycle).snapshotForWindow(
          client.scope,
          session,
        )
      : backend.snapshot(session);

  Future<void> _snapshot(_Client client) async {
    if (client.privileged && backend is PrivilegedBridgeBackend) {
      final privileged = backend as PrivilegedBridgeBackend;
      if (client.hostRevision != privileged.revision) {
        if (_send(client, {
          'v': 1,
          'type': 'event',
          'event': 'host.changed',
          'seq': ++client.seq,
          'data': {'revision': privileged.revision},
        })) {
          client.hostRevision = privileged.revision;
        }
      }
      return;
    }
    if (client.snapshotBusy) return;
    final hostRevision = backend is PrivilegedBridgeBackend
        ? (backend as PrivilegedBridgeBackend).revision
        : null;
    final active = const {
      'running',
      'retrying',
      'approval',
    }.contains((client.previousSnapshot?['session'] as Map?)?['status']);
    if (hostRevision != null &&
        client.hostRevision == hostRevision &&
        client.previousSnapshot != null &&
        client.snapshotError == null &&
        DateTime.now().difference(client.lastSnapshotAt) <
            Duration(seconds: active ? 1 : 10)) {
      return;
    }
    client.snapshotBusy = true;
    try {
      final session = client.session;
      final snapshot = await _clientSnapshot(client, session);
      client.hostRevision = hostRevision ?? -1;
      client.lastSnapshotAt = DateTime.now();
      if (client.session != session || !_clients.contains(client)) return;
      final signature = jsonEncode(snapshot);
      if (signature != client.lastSnapshot || client.snapshotError != null) {
        if (utf8.encode(signature).length > 8 * 1024 * 1024 - 512) {
          _snapshotError(client, 'too_large', '快照超过 8 MiB，请在 GUI 查看完整记录');
          return;
        }
        if (client.previousSnapshot case final previous?
            when !client.patchSnapshots) {
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
        final cursor = client.snapshotCursor + 1;
        final patch =
            client.patchSnapshots &&
            client.previousSnapshot != null &&
            client.snapshotError == null;
        final sent = _send(client, {
          'v': 1,
          'type': 'event',
          'seq': ++client.seq,
          'session_id': session,
          'event': patch ? 'snapshot.patch' : 'snapshot',
          if (client.patchSnapshots) 'cursor': cursor,
          'data': patch
              ? bridgeSnapshotPatch(
                  client.previousSnapshot!,
                  snapshot,
                  client.snapshotCursor,
                  cursor,
                )
              : snapshot,
        });
        if (sent) {
          client.previousSnapshot = snapshot;
          client.lastSnapshot = signature;
          client.snapshotError = null;
          client.snapshotCursor = cursor;
        }
      }
    } catch (_) {
      _snapshotError(client, 'snapshot_failed', '状态刷新失败，当前显示可能已过期；正在重试。');
    } finally {
      client.snapshotBusy = false;
    }
  }

  Future<void> _finishRelease(_WindowRelease release) async {
    if (release.done.isCompleted || release.client.releasing) return;
    release.client.releasing = true;
    if (identical(_windowReleases[release.client.clientId], release)) {
      _windowReleases.remove(release.client.clientId);
    }
    release.timer?.cancel();
    try {
      if (backend case BridgeClientLifecycle lifecycle) {
        await lifecycle.releaseClient(release.client.scope);
      }
    } finally {
      if (!release.done.isCompleted) release.done.complete();
    }
  }

  Future<void> _releaseClient(_Client client, {bool immediate = false}) {
    if (client.cleanup case final pending?) {
      final release = _windowReleases[client.clientId];
      if (immediate && release != null && identical(release.client, client)) {
        unawaited(_finishRelease(release).catchError((Object _) {}));
      }
      return pending;
    }
    final release = _WindowRelease(client);
    final operation = release.done.future;
    client.cleanup = operation;
    _clientCleanups.add(operation);
    unawaited(operation.whenComplete(() => _clientCleanups.remove(operation)));
    if (client.authenticated &&
        client.windowScoped &&
        !immediate &&
        !_stopping) {
      _windowReleases[client.clientId] = release;
      release.timer = Timer(const Duration(seconds: 5), () {
        unawaited(_finishRelease(release).catchError((Object _) {}));
      });
    } else {
      unawaited(_finishRelease(release).catchError((Object _) {}));
    }
    return operation;
  }

  Future<void> stop() async {
    _stopping = true;
    _updates?.cancel();
    _updates = null;
    for (final client in _clients.toList()) {
      await client.socket.close(WebSocketStatus.goingAway);
      await _releaseClient(client, immediate: true);
    }
    for (final release in _windowReleases.values.toList()) {
      await _finishRelease(release);
    }
    _clients.clear();
    await Future.wait(_clientCleanups.toList());
    await _server?.close(force: true);
    _server = null;
    await discovery.remove();
    _token = null;
    await onStopped?.call();
  }
}

class _WindowRelease {
  _WindowRelease(this.client);
  final _Client client;
  final done = Completer<void>();
  Timer? timer;
}

class _Client {
  _Client(this.socket);
  final WebSocket socket;
  Future<void>? cleanup;
  String scope = const Uuid().v4();
  bool windowScoped = false, windowClosing = false, releasing = false;
  bool authenticated = false, snapshotBusy = false;
  bool privileged = false;
  bool patchSnapshots = false;
  int snapshotCursor = 0;
  int hostRevision = -1;
  String clientId = '', lastSnapshot = '';
  String? session, snapshotError;
  int seq = 0, openRevision = 0;
  final openRequests = <String, int>{};
  DateTime lastRequest = DateTime.now();
  DateTime lastSnapshotAt = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, Object?>? previousSnapshot;
}
