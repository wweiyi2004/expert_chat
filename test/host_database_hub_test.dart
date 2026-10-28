import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
// Both endpoints ship Drift 2.33.0; compatibility is checked by transport tests.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/domain/host/database_hub.dart';
import 'package:expert_chat/domain/host/host_client.dart';
import 'package:expert_chat/domain/host/reconnecting_database.dart';

class _DatabaseClient extends HostClient {
  _DatabaseClient(this.port)
    : super(discoveryDirectory: Directory.systemTemp, hostExecutable: 'unused');
  final int port;
  final sockets = <WebSocket>[];
  @override
  bool get connected => true;
  @override
  Future<WebSocket> openDatabase() async {
    final socket = await WebSocket.connect('ws://127.0.0.1:$port');
    sockets.add(socket);
    return socket;
  }

  @override
  void reportError(String message) {}
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late DriftServer owner;
  late HostDatabaseHub hub;
  late HttpServer server;
  late AppDatabase host, first, second;
  late _DatabaseClient clientA, clientB;
  setUp(() async {
    owner = DriftServer(NativeDatabase.memory());
    final local = StreamChannelController<Object?>(sync: true);
    unawaited(owner.serve(local.local));
    host = AppDatabase(await connectToRemoteAndInitialize(local.foreign));
    await host.customSelect('SELECT 1').get();
    hub = HostDatabaseHub(owner);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      unawaited(hub.attach(socket));
    });
    clientA = _DatabaseClient(server.port);
    clientB = _DatabaseClient(server.port);
    final a = ReconnectingHostDatabase(clientA),
        b = ReconnectingHostDatabase(clientB);
    first = AppDatabase(a.connection);
    second = AppDatabase(b.connection);
    a.tableNames = first.allTables.map((t) => t.actualTableName).toSet();
    b.tableNames = second.allTables.map((t) => t.actualTableName).toSet();
  });
  tearDown(() async {
    await first.close();
    await second.close();
    await clientA.close();
    await clientB.close();
    await hub.close();
    await server.close(force: true);
    await host.close();
    await owner.shutdown();
  });
  test('SQL updates are visible to another client watch stream', () async {
    final observed = Completer<void>();
    final subscription = second.select(second.conversations).watch().listen((
      rows,
    ) {
      if (rows.any((r) => r.id == 'shared') && !observed.isCompleted) {
        observed.complete();
      }
    });
    addTearDown(subscription.cancel);
    await first
        .into(first.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'shared',
            updatedAt: DateTime.now(),
          ),
        );
    await observed.future.timeout(const Duration(seconds: 5));
  });
  test(
    'lost GUI transaction rolls back and a fresh connection can write without replay',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final transaction = first.transaction(() async {
        await first
            .into(first.conversations)
            .insert(
              ConversationsCompanion.insert(
                id: 'uncommitted',
                updatedAt: DateTime.now(),
              ),
            );
        entered.complete();
        await release.future;
      });
      final failure = expectLater(transaction, throwsA(anything));
      await entered.future.timeout(const Duration(seconds: 5));
      await clientA.sockets.last.close();
      release.complete();
      await failure;
      final rows = await second
          .select(second.conversations)
          .get()
          .timeout(const Duration(seconds: 5));
      expect(rows.any((r) => r.id == 'uncommitted'), isFalse);
      await first
          .into(first.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'after-reconnect',
              updatedAt: DateTime.now(),
            ),
          );
      expect(
        (await second.select(second.conversations).get()).map((r) => r.id),
        contains('after-reconnect'),
      );
    },
  );
  test('maintenance rejects new client SQL until its scope ends', () async {
    await first.customSelect('SELECT 1').get();
    final entered = Completer<void>(), release = Completer<void>();
    final maintenance = hub.maintenance(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    await expectLater(
      first
          .into(first.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: 'blocked',
              updatedAt: DateTime.now(),
            ),
          ),
      throwsA(anything),
    );
    release.complete();
    await maintenance;
    expect(await first.select(first.conversations).get(), isEmpty);
  });
  test(
    'a connection closed before Drift handshake fails promptly and can reconnect',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final maintenance = hub.maintenance(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      try {
        await expectLater(
          first
              .customSelect('SELECT 1')
              .get()
              .timeout(const Duration(seconds: 2)),
          throwsA(
            isA<HostRpcException>().having(
              (error) => error.code,
              'code',
              'database_not_open',
            ),
          ),
        );
      } finally {
        release.complete();
        await maintenance;
      }
      expect(
        (await first.customSelect('SELECT 1 AS ready').get())
            .single
            .data['ready'],
        1,
      );
    },
  );
}
