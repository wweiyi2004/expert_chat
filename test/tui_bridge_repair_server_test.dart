import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/features/tui_bridge/server.dart';
import 'package:expert_chat/features/tui_bridge/discovery.dart';
import 'package:expert_chat/features/tui_bridge/protocol.dart';

class _Discovery extends BridgeDiscovery {
  _Discovery() : super(Directory.systemTemp);
  @override
  Future<String> publish(int port) async => 'isolated-token';
  @override
  Future<void> remove() async {}
}

class _Backend implements BridgeBackend {
  bool large = false, fail = false;
  bool stopCalled = false;
  final openGate = Completer<void>();
  final openEntered = Completer<void>();
  final entered = Completer<void>(), gate = Completer<void>();
  int invocations = 0;
  @override
  List<String> get capabilities => ['suspend.invoke', 'task.stop'];
  @override
  Future<Map<String, Object?>> invoke(String m, Map<String, dynamic> p) async {
    if (m == 'task.stop') {
      stopCalled = true;
      return {'accepted': true};
    }
    invocations++;
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    return {'accepted': true};
  }

  @override
  Future<Map<String, Object?>> snapshot(String? s) async {
    if (fail) throw StateError('refresh');
    if (s == 'slow-session') {
      if (!openEntered.isCompleted) openEntered.complete();
      await openGate.future;
    }
    return {
      'session': s == null ? null : {'id': s},
      'messages': [
        {
          'id': 'm',
          'role': 'user',
          'text': large ? 'x' * (8 * 1024 * 1024) : 'small',
        },
      ],
    };
  }
}

void main() {
  test(
    'oversize and failed automatic snapshots emit scoped sequenced errors and recover',
    () async {
      final b = _Backend();
      final server = TuiBridgeServer(backend: b, discovery: _Discovery());
      await server.start();
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/tui');
      final frames = <Map<String, dynamic>>[];
      ws.listen((x) => frames.add(jsonDecode(x as String)));
      void send(String id, String method, Map<String, Object?> p) =>
          ws.add(jsonEncode({'v': 1, 'id': id, 'method': method, 'params': p}));
      Future<void> until(bool Function() test) async {
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!test()) {
          if (DateTime.now().isAfter(end)) fail('timeout');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      try {
        send('hello', 'hello', {
          'protocol': 1,
          'client_id': 'audit',
          'token': 'isolated-token',
        });
        await until(() => frames.any((f) => f['event'] == 'snapshot'));
        frames.clear();
        b.large = true;
        await until(() => frames.any((f) => f['event'] == 'request.error'));
        expect(frames.single['data']['code'], 'too_large');
        expect(frames.single['data']['scope'], 'snapshot');
        expect(frames.single['seq'], isA<int>());
        b.large = false;
        await until(() => frames.any((f) => f['event'] == 'snapshot'));
        frames.clear();
        b.fail = true;
        await until(() => frames.any((f) => f['event'] == 'request.error'));
        expect(frames.single['data']['code'], 'snapshot_failed');
        b.fail = false;
        await until(() => frames.any((f) => f['event'] == 'snapshot'));
      } finally {
        await ws.close();
        await server.stop();
      }
    },
  );
  test('late session.open result cannot replace newer subscription', () async {
    final b = _Backend();
    final server = TuiBridgeServer(backend: b, discovery: _Discovery());
    await server.start();
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/tui');
    final frames = <Map<String, dynamic>>[];
    final hello = Completer<void>();
    ws.listen((x) {
      final f = jsonDecode(x as String) as Map<String, dynamic>;
      frames.add(f);
      if (f['id'] == 'hello') hello.complete();
    });
    void send(String id, String method, Map<String, Object?> params) => ws.add(
      jsonEncode({'v': 1, 'id': id, 'method': method, 'params': params}),
    );
    try {
      send('hello', 'hello', {
        'protocol': 1,
        'client_id': 'one',
        'token': 'isolated-token',
      });
      await hello.future;
      send('old', 'session.open', {'session_id': 'slow-session'});
      await b.openEntered.future;
      send('new', 'session.open', {'session_id': 'new-session'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      b.openGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        frames.where((f) => f['event'] == 'snapshot').last['session_id'],
        'new-session',
      );
      expect(
        frames.firstWhere((f) => f['id'] == 'old')['error']['code'],
        'superseded',
      );
      expect(frames.firstWhere((f) => f['id'] == 'new')['ok'], true);
    } finally {
      if (!b.openGate.isCompleted) b.openGate.complete();
      await ws.close();
      await server.stop();
    }
  });
  test(
    'same connection ping and stop bypass pending mutation without replay',
    () async {
      final b = _Backend();
      final server = TuiBridgeServer(backend: b, discovery: _Discovery());
      await server.start();
      final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/tui');
      final frames = <Map<String, dynamic>>[];
      final hello = Completer<void>();
      ws.listen((x) {
        final f = jsonDecode(x as String) as Map<String, dynamic>;
        frames.add(f);
        if (f['id'] == 'hello') hello.complete();
      });
      void send(String id, String method, Map<String, Object?> params) =>
          ws.add(
            jsonEncode({'v': 1, 'id': id, 'method': method, 'params': params}),
          );
      try {
        send('hello', 'hello', {
          'protocol': 1,
          'client_id': 'one',
          'token': 'isolated-token',
        });
        await hello.future;
        send('slow', 'suspend.invoke', {'session_id': 'a'});
        await b.entered.future;
        send('slow', 'suspend.invoke', {'session_id': 'a'});
        send('ping', 'ping', {});
        send('stop', 'task.stop', {'session_id': 'a'});
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(frames.any((f) => f['id'] == 'ping'), true);
        expect(b.stopCalled, true);
        expect(frames.any((f) => f['id'] == 'stop'), true);
        expect(b.invocations, 1);
      } finally {
        if (!b.gate.isCompleted) b.gate.complete();
        await ws.close();
        await server.stop();
      }
    },
  );
  test(
    'other connection ping and other session mutation bypass suspended operation; same id dedups',
    () async {
      final b = _Backend();
      final server = TuiBridgeServer(backend: b, discovery: _Discovery());
      await server.start();
      final sockets = <WebSocket>[];
      Future<(WebSocket, List<Map<String, dynamic>>)> connect(
        String client,
      ) async {
        final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/tui');
        sockets.add(ws);
        final frames = <Map<String, dynamic>>[];
        final hello = Completer<void>();
        ws.listen((x) {
          final f = jsonDecode(x as String) as Map<String, dynamic>;
          frames.add(f);
          if (f['id'] == 'hello') hello.complete();
        });
        ws.add(
          jsonEncode({
            'v': 1,
            'id': 'hello',
            'method': 'hello',
            'params': {
              'protocol': 1,
              'client_id': client,
              'token': 'isolated-token',
            },
          }),
        );
        await hello.future;
        return (ws, frames);
      }

      void send(
        WebSocket ws,
        String id,
        String method,
        Map<String, Object?> p,
      ) =>
          ws.add(jsonEncode({'v': 1, 'id': id, 'method': method, 'params': p}));
      try {
        final a = await connect('a'), c = await connect('b');
        send(a.$1, 'slow', 'suspend.invoke', {'session_id': 'a'});
        await b.entered.future;
        send(c.$1, 'ping', 'ping', {});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(c.$2.any((f) => f['id'] == 'ping'), true);
        send(c.$1, 'other', 'suspend.invoke', {'session_id': 'b'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(b.invocations, 2);
        b.gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        send(c.$1, 'other', 'suspend.invoke', {'session_id': 'b'});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(b.invocations, 2);
      } finally {
        if (!b.gate.isCompleted) b.gate.complete();
        for (final ws in sockets) {
          await ws.close();
        }
        await server.stop();
      }
    },
  );
}
