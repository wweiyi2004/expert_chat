import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart';
// Both endpoints ship Drift 2.33.0; compatibility is checked by transport tests.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:stream_channel/stream_channel.dart';
import 'database_channel.dart';

/// Each GUI connection owns its nested SQL executors. Disconnect rolls those
/// back so a dead client cannot retain the shared database transaction lock.
class HostDatabaseHub {
  HostDatabaseHub(this.owner);
  final DriftServer owner;
  late final _updates = owner.tableUpdateNotifications.asBroadcastStream();
  final _clients = <_DatabaseClient>{};
  bool _maintenance = false, _closed = false;
  int _active = 0, _leases = 0;
  void _admit() {
    if (_maintenance || _closed) throw StateError('数据库正在维护，本次操作未发送');
  }

  Future<void> attach(WebSocket socket) async {
    if (_maintenance || _closed) {
      await socket.close(WebSocketStatus.goingAway);
      return;
    }
    final channels = StreamChannelController<Object?>(sync: true);
    unawaited(owner.serve(channels.local));
    final connection = await connectToRemoteAndInitialize(channels.foreign);
    final client = _DatabaseClient(this, connection, socket);
    _clients.add(client);
    final server = DriftServer(
      _TrackedExecutor(client, connection.executor),
      closeConnectionAfterShutdown: false,
    );
    final outgoing = _updates.listen(server.dispatchTableUpdateNotification);
    final incoming = server.tableUpdateNotifications.listen(
      (note) =>
          connection.streamQueries.handleTableUpdates(note.updates.toSet()),
    );
    try {
      await server.serve(databaseChannel(socket));
    } finally {
      client.closed = true;
      await outgoing.cancel();
      await incoming.cancel();
      await client.release();
      await server.shutdown();
      await connection.close();
      _clients.remove(client);
    }
  }

  Future<T> maintenance<T>(Future<T> Function() action) async {
    if (_maintenance) throw StateError('已有数据维护正在进行');
    _maintenance = true;
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (_active != 0 || _leases != 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('仍有客户端数据库操作，请完成编辑后重试');
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      return await action();
    } finally {
      _maintenance = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final client in _clients.toList()) {
      client.closed = true;
      await client.socket.close();
      await client.release();
    }
  }
}

class _DatabaseClient {
  _DatabaseClient(this.hub, this.connection, this.socket);
  final HostDatabaseHub hub;
  final DatabaseConnection connection;
  final WebSocket socket;
  final leases = <_TrackedExecutor>[];
  bool closed = false;
  Future<void>? _releasing;
  Future<void> release() => _releasing ??= _release();
  Future<void> _release() async {
    for (final lease in leases.toList().reversed) {
      try {
        if (lease is _TrackedTransaction) {
          await lease.rollback();
        } else {
          await lease.close();
        }
      } catch (_) {
        /* Closing the underlying connection still follows. */
      }
    }
  }
}

class _TrackedExecutor extends QueryExecutor {
  _TrackedExecutor(this.client, this.delegate, {this.nested = false});
  final _DatabaseClient client;
  final QueryExecutor delegate;
  final bool nested;
  bool opened = false, released = false;
  Future<T> _run<T>(Future<T> Function() action) async {
    if (client.closed || released) throw StateError('数据库客户端已断开');
    if (!nested) client.hub._admit();
    client.hub._active++;
    try {
      return await action();
    } finally {
      client.hub._active--;
    }
  }

  void _release() {
    if (opened && nested && !released) {
      client.hub._leases--;
      client.leases.remove(this);
    }
    released = true;
  }

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    if (!opened && nested) {
      client.hub._admit();
      opened = true;
      client.hub._leases++;
      client.leases.add(this);
    }
    try {
      return await _run(() => delegate.ensureOpen(user));
    } catch (_) {
      if (nested) _release();
      rethrow;
    }
  }

  @override
  SqlDialect get dialect => delegate.dialect;
  @override
  Future<List<Map<String, Object?>>> runSelect(String s, List<Object?> a) =>
      _run(() => delegate.runSelect(s, a));
  @override
  Future<int> runInsert(String s, List<Object?> a) =>
      _run(() => delegate.runInsert(s, a));
  @override
  Future<int> runUpdate(String s, List<Object?> a) =>
      _run(() => delegate.runUpdate(s, a));
  @override
  Future<int> runDelete(String s, List<Object?> a) =>
      _run(() => delegate.runDelete(s, a));
  @override
  Future<void> runCustom(String s, [List<Object?>? a]) =>
      _run(() => delegate.runCustom(s, a));
  @override
  Future<void> runBatched(BatchedStatements s) =>
      _run(() => delegate.runBatched(s));
  @override
  TransactionExecutor beginTransaction() =>
      _TrackedTransaction(client, delegate.beginTransaction());
  @override
  QueryExecutor beginExclusive() =>
      _TrackedExecutor(client, delegate.beginExclusive(), nested: true);
  @override
  Future<void> close() async {
    if (released) return;
    try {
      await delegate.close();
    } finally {
      _release();
    }
  }
}

class _TrackedTransaction extends _TrackedExecutor
    implements TransactionExecutor {
  _TrackedTransaction(super.client, TransactionExecutor super.delegate)
    : super(nested: true);
  TransactionExecutor get transaction => delegate as TransactionExecutor;
  @override
  bool get supportsNestedTransactions => transaction.supportsNestedTransactions;
  @override
  Future<void> send() async {
    if (released) return;
    try {
      await transaction.send();
      _release();
    } catch (_) {
      rethrow;
    }
  }

  @override
  Future<void> rollback() async {
    if (released) return;
    try {
      await transaction.rollback();
    } finally {
      _release();
    }
  }

  @override
  Future<void> close() => rollback();
}
