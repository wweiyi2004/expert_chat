import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:expert_chat/data/research/ssh_profile.dart';
import 'package:expert_chat/domain/research/ssh_remote_forwarding.dart';
import 'package:expert_chat/domain/research/research_ssh_contract.dart';
import 'package:flutter_test/flutter_test.dart';

class _Forward implements SSHRemoteForward {
  final incoming = StreamController<SSHForwardChannel>.broadcast();
  @override
  String get host => 'localhost';
  @override
  int get port => 10808;
  @override
  Stream<SSHForwardChannel> get connections => incoming.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements SSHClient {
  final requests = <(String?, int?)>[];
  final forward = _Forward();
  bool reject = false;
  @override
  Future<SSHRemoteForward?> forwardRemote({
    String? host,
    int? port,
    SSHRemoteConnectionFilter? filter,
  }) async {
    requests.add((host, port));
    return reject ? null : forward;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Channel implements SSHForwardChannel {
  final incoming = StreamController<Uint8List>();
  final outgoing = StreamController<List<int>>();
  final finished = Completer<void>();
  bool destroyed = false;
  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  StreamSink<List<int>> get sink => outgoing.sink;
  @override
  Future<void> get done => finished.future;
  @override
  void destroy() {
    if (destroyed) return;
    destroyed = true;
    unawaited(incoming.close());
    finished.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'optional RemoteForward accepts OpenSSH syntax and round-trips profiles',
    () {
      expect(SshRemoteForward.parseLines('  '), isEmpty);
      final rules = SshRemoteForward.parseLines(
        'RemoteForward 10808 127.0.0.1:7890\n[::1]:10809 [::1]:7891',
      );
      expect(rules.first.bindHost, 'localhost');
      expect(rules.first.bindPort, 10808);
      expect(rules.first.targetHost, '127.0.0.1');
      expect(rules.first.targetPort, 7890);
      expect(rules.last.configLine, '[::1]:10809 [::1]:7891');
      final profile = SshProfile(
        id: 's',
        name: 'SSH',
        host: 'server',
        username: 'timer',
        remoteForwards: rules,
      );
      final restored = SshProfile.fromJson(profile.toJson())!;
      expect(restored.remoteForwardText, profile.remoteForwardText);
      expect(restored.copyWith(name: 'renamed').remoteForwards.length, 2);
      expect(restored.copyWith(remoteForwards: []).remoteForwardText, '');
      expect(
        SshProfile.fromJson({
          'id': 'old',
          'host': 'h',
          'username': 'u',
        })!.remoteForwards,
        isEmpty,
      );
    },
  );
  test('invalid forwarding never gets saved as a partial rule', () {
    for (final text in [
      '10808',
      '10808 localhost:0',
      '65536 localhost:7890',
      '10808 localhost:abc',
      '10808 localhost:7890 extra',
      '10808 bad/path:7890',
      '10808 localhost:7890\n10808 localhost:7891',
    ]) {
      expect(
        () => SshRemoteForward.parseLines(text),
        throwsFormatException,
        reason: text,
      );
    }
  });
  test(
    'empty setting does not request a listener and refused listener is explicit',
    () async {
      final client = _Client(), manager = SshRemoteForwarding();
      await manager.start(client, []);
      expect(client.requests, isEmpty);
      client.reject = true;
      await expectLater(
        manager.start(
          client,
          SshRemoteForward.parseLines('10808 127.0.0.1:7890'),
        ),
        throwsA(
          isA<ResearchSshException>().having(
            (e) => e.message,
            'message',
            contains('被服务器拒绝'),
          ),
        ),
      );
      await manager.close();
      await client.forward.incoming.close();
    },
  );
  test(
    'remote channel forwards bytes to local TCP and disconnect closes both ends',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = <Socket>[];
      final serverSubscription = server.listen((socket) {
        accepted.add(socket);
        socket.listen(
          socket.add,
          onDone: socket.destroy,
          onError: (_) => socket.destroy(),
        );
      });
      final errors = <String>[];
      final manager = SshRemoteForwarding(onError: errors.add),
          client = _Client();
      final channel = _Channel();
      final returned = <int>[];
      final received = Completer<void>();
      final payload = List<int>.generate(1024 * 1024, (i) => i % 251);
      final listener = channel.outgoing.stream.listen((bytes) {
        returned.addAll(bytes);
        if (returned.length >= payload.length && !received.isCompleted) {
          received.complete();
        }
      });
      try {
        await manager.start(client, [
          SshRemoteForward(
            bindPort: 10808,
            targetHost: '127.0.0.1',
            targetPort: server.port,
          ),
        ]);
        expect(client.requests, [('localhost', 10808)]);
        client.forward.incoming.add(channel);
        channel.incoming.add(Uint8List.fromList(payload));
        await received.future.timeout(const Duration(seconds: 5));
        expect(returned, payload);
        expect(errors, isEmpty);
        await manager.close();
        expect(channel.destroyed, true);
        final stale = _Channel();
        client.forward.incoming.add(stale);
        await Future<void>.delayed(Duration.zero);
        // A cancelled subscription must not open another local TCP connection.
        expect(accepted.length, 1);
        stale.destroy();
      } finally {
        await manager.close();
        channel.destroy();
        await listener.cancel();
        for (final socket in accepted) {
          socket.destroy();
        }
        await serverSubscription.cancel();
        await server.close();
        await client.forward.incoming.close();
      }
    },
  );
  test(
    'unavailable local target closes the channel and reports the failed mapping',
    () async {
      final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = reserved.port;
      await reserved.close();
      final failed = Completer<String>(), client = _Client();
      final manager = SshRemoteForwarding(
        onError: (message) {
          if (!failed.isCompleted) failed.complete(message);
        },
      );
      final channel = _Channel();
      channel.outgoing.stream.listen((_) {});
      await manager.start(client, [
        SshRemoteForward(
          bindPort: 10808,
          targetHost: '127.0.0.1',
          targetPort: port,
        ),
      ]);
      client.forward.incoming.add(channel);
      expect(
        await failed.future.timeout(const Duration(seconds: 3)),
        contains('连接本地目标失败'),
      );
      await manager.close();
      expect(channel.destroyed, true);
      await client.forward.incoming.close();
    },
  );
}
