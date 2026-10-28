// The pinned remote adapter bridges Drift's exposed internal stream store.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart';
// Both endpoints ship Drift 2.33.0; compatibility is checked by transport tests.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
// Drift's remote store is internal too. Keep this small adapter pinned to the
// exact Drift version used by both bundled host and GUI.
// ignore: implementation_imports
import 'package:drift/src/runtime/executor/stream_queries.dart';
import 'host_client.dart';
import 'database_channel.dart';

class ReconnectingHostDatabase extends _ForwardExecutor {
  ReconnectingHostDatabase(this.client) {
    _events = client.updates.listen((_) {
      if (_remote == null && client.connected && _user != null) {
        unawaited(_recover());
      }
    });
  }
  final HostClient client;
  final store = _HostStreamStore();
  Set<String> tableNames = {};
  DatabaseConnection get connection =>
      DatabaseConnection(this, streamQueries: store);
  DatabaseConnection? _remote;
  WebSocket? _socket;
  QueryExecutorUser? _user;
  Future<QueryExecutor>? _opening;
  StreamSubscription? _tables, _events;
  Timer? _retry;
  bool _closed = false;
  @override
  Future<QueryExecutor> executor() {
    if (_closed) throw StateError('数据库连接已关闭');
    if (!client.connected) {
      throw const HostRpcException('disconnected', '宿主未连接；数据库操作未发送');
    }
    if (_remote != null && _socket?.readyState == WebSocket.open) {
      return Future.value(_remote!.executor);
    }
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<QueryExecutor> _open() async {
    final socket = await client.openDatabase();
    if (_closed) {
      await socket.close();
      throw StateError('数据库连接已关闭');
    }
    final closed = Completer<void>();
    final remote =
        await Future.any<DatabaseConnection>([
          connectToRemoteAndInitialize(
            databaseChannel(
              socket,
              onClosed: () {
                if (!closed.isCompleted) closed.complete();
                _lost(socket);
              },
            ),
          ),
          closed.future.then(
            (_) => throw const HostRpcException(
              'database_not_open',
              '数据库连接尚未建立便已关闭；本次操作未发送。',
            ),
          ),
        ]).timeout(
          const Duration(seconds: 5),
          onTimeout: () async {
            await socket.close();
            throw const HostRpcException(
              'database_open_timeout',
              '数据库连接超时；本次操作未发送。',
            );
          },
        );
    if (_closed || socket.readyState != WebSocket.open) {
      await remote.close();
      throw StateError('数据库连接未建立');
    }
    _socket = socket;
    _remote = remote;
    await _tables?.cancel();
    _tables = remote.streamQueries
        .updatesForSync(const TableUpdateQuery.any())
        .listen(store.receive);
    store.remote = remote.streamQueries;
    try {
      if (_user case final user?) await remote.ensureOpen(user);
    } catch (_) {
      _lost(socket);
      rethrow;
    }
    store.receive({for (final name in tableNames) TableUpdate(name)});
    return remote.executor;
  }

  void _lost(WebSocket socket) {
    if (_socket != null && !identical(_socket, socket)) return;
    _socket = null;
    _remote = null;
    store.remote = null;
    unawaited(_tables?.cancel());
    _tables = null;
    if (!_closed) {
      client.reportError('数据库连接中断；进行中的写入结果需核对，未自动重放。');
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 1), () => unawaited(_recover()));
    }
  }

  Future<void> _recover() async {
    if (_closed || _remote != null || !client.connected) return;
    try {
      await executor();
    } catch (_) {
      if (!_closed) {
        _retry?.cancel();
        _retry = Timer(const Duration(seconds: 2), () => unawaited(_recover()));
      }
    }
  }

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    _user = user;
    return (await executor()).ensureOpen(user);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _events?.cancel();
    await _tables?.cancel();
    await _remote?.close();
    await _socket?.close();
    await store.close();
  }
}

class _HostStreamStore extends StreamQueryStore {
  StreamQueryStore? remote;
  void receive(Set<TableUpdate> updates) => super.handleTableUpdates(updates);
  @override
  void handleTableUpdates(Set<TableUpdate> updates) {
    final target = remote;
    if (target == null) {
      super.handleTableUpdates(updates);
    } else {
      target.handleTableUpdates(updates);
    }
  }
}

/// No query is retried after it is sent. Nested transactions/exclusive leases
/// capture one connection and can never migrate halfway to a fresh connection.
abstract class _ForwardExecutor extends QueryExecutor {
  Future<QueryExecutor> executor();
  @override
  SqlDialect get dialect => SqlDialect.sqlite;
  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async =>
      (await executor()).ensureOpen(user);
  @override
  Future<List<Map<String, Object?>>> runSelect(
    String sql,
    List<Object?> args,
  ) async => (await executor()).runSelect(sql, args);
  @override
  Future<int> runInsert(String sql, List<Object?> args) async =>
      (await executor()).runInsert(sql, args);
  @override
  Future<int> runUpdate(String sql, List<Object?> args) async =>
      (await executor()).runUpdate(sql, args);
  @override
  Future<int> runDelete(String sql, List<Object?> args) async =>
      (await executor()).runDelete(sql, args);
  @override
  Future<void> runCustom(String sql, [List<Object?>? args]) async =>
      (await executor()).runCustom(sql, args);
  @override
  Future<void> runBatched(BatchedStatements statements) async =>
      (await executor()).runBatched(statements);
  @override
  TransactionExecutor beginTransaction() =>
      _PinnedTransaction(executor().then((e) => e.beginTransaction()));
  @override
  QueryExecutor beginExclusive() =>
      _PinnedExecutor(executor().then((e) => e.beginExclusive()));
}

class _PinnedExecutor extends _ForwardExecutor {
  _PinnedExecutor(this.delegate);
  final Future<QueryExecutor> delegate;
  @override
  Future<QueryExecutor> executor() => delegate;
  @override
  Future<void> close() async => (await delegate).close();
}

class _PinnedTransaction extends _PinnedExecutor
    implements TransactionExecutor {
  _PinnedTransaction(Future<TransactionExecutor> super.delegate);
  @override
  bool get supportsNestedTransactions => true;
  @override
  Future<void> send() async => ((await delegate) as TransactionExecutor).send();
  @override
  Future<void> rollback() async =>
      ((await delegate) as TransactionExecutor).rollback();
}
