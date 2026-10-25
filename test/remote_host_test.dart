import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:expert_chat/domain/remote/remote_host.dart';

void main() {
  late Directory fixture;
  late RemoteHost host;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('expert-remote-test-');
    final work = await Directory('${fixture.path}/work').create();
    host = RemoteHost(
      Directory('${fixture.path}/private'),
      work,
      token: 'test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    );
    await host.open();
  });
  tearDown(() async {
    await host.close();
    await fixture.delete(recursive: true);
  });

  Future<void> until(bool Function() condition) async {
    final until = DateTime.now().add(const Duration(seconds: 15));
    while (!condition()) {
      if (DateTime.now().isAfter(until)) {
        fail('Timed out waiting for host state');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  test(
    'submission identity includes kind; simultaneous approval dispatches once',
    () async {
      final command = Platform.isWindows
          ? "Add-Content once.txt 'one'"
          : "echo one >> once.txt";
      await host.submit({'id': 'one', 'command': command});
      expect(
        await host.submit({'id': 'one', 'command': command}),
        same(host.tasks['one']),
      );
      await expectLater(
        host.submit({'id': 'one', 'goal': command}),
        throwsStateError,
      );
      final approvals = await Future.wait([
        host.approve('one').then((_) => true).catchError((_) => false),
        host.approve('one').then((_) => true).catchError((_) => false),
      ]);
      expect(approvals.where((ok) => ok).length, 1);
      await until(() => host.tasks['one']!['state'] == 'completed');
      expect(
        (await File('${host.workspace.path}/once.txt').readAsLines()).length,
        1,
      );
    },
  );

  test('auth, network protection, disconnect and event continuation', () async {
    await expectLater(
      host.listen(address: '0.0.0.0', allowNetwork: true),
      throwsArgumentError,
    );
    await host.listen();
    final client = HttpClient();
    var request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}/v1/tasks'),
    );
    expect((await request.close()).statusCode, 401);
    await host.submit({
      'id': 'offline',
      'command': Platform.isWindows ? "Write-Output 'done'" : 'echo done',
    });
    await host.approve('offline');
    await until(() => host.tasks['offline']!['state'] == 'completed');
    request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}/v1/events?after=1'),
    );
    request.headers.set(
      'Authorization',
      'Bearer test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    );
    final payload = jsonDecode(
      await utf8.decoder.bind(await request.close()).join(),
    );
    expect((payload['events'] as List).first['cursor'], 2);
    client.close(force: true);
  });

  test(
    'headless real model-tool-model loop pauses for command approval',
    () async {
      final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      model.listen((request) async {
        final input = jsonDecode(await utf8.decoder.bind(request).join());
        requests++;
        final message = requests == 1
            ? {
                'role': 'assistant',
                'content': null,
                'tool_calls': [
                  {
                    'id': 'tool1',
                    'type': 'function',
                    'function': {
                      'name': 'shell',
                      'arguments': jsonEncode({
                        'command': Platform.isWindows
                            ? "Write-Output 'verified'"
                            : 'echo verified',
                      }),
                    },
                  },
                ],
              }
            : {'role': 'assistant', 'content': 'Verified result'};
        if (requests == 2) {
          expect((input['messages'] as List).last['role'], 'tool');
        }
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        if (requests == 1) (message['tool_calls'] as List).first['index'] = 0;
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'delta': message, 'finish_reason': requests == 1 ? 'tool_calls' : 'stop'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${model.port}/chat/completions';
      host.modelName = 'fixture';
      await host.submit({'id': 'agent', 'goal': 'Verify a fixture'});
      await host.approve('agent');
      await until(
        () =>
            host.tasks['agent']!['pendingCommand'] != null &&
            host.tasks['agent']!['state'] == 'awaitingApproval',
      );
      expect(host.tasks['agent']!['state'], 'awaitingApproval');
      expect(requests, 1);
      await host.approve('agent');
      await until(() => host.tasks['agent']!['state'] == 'completed');
      expect(host.tasks['agent']!['result'], 'Verified result');
      expect(requests, 2);
      await model.close(force: true);
    },
  );

  test(
    'restart preserves identity and marks uncertain dispatch without replay',
    () async {
      await host.submit({'id': 'uncertain', 'command': 'do not execute'});
      await host.close();
      final journal = File('${host.directory.path}/events.jsonl');
      final task = {...host.tasks['uncertain']!, 'state': 'running'};
      await journal.writeAsString(
        '${jsonEncode({'cursor': 2, 'kind': 'state', 'task': task})}\n',
        mode: FileMode.append,
      );
      host = RemoteHost(host.directory, host.workspace);
      await host.open();
      expect(host.tasks['uncertain']!['state'], 'unknown');
      await expectLater(host.approve('uncertain'), throwsStateError);
    },
  );

  test(
    'automation webhook deduplicates and pause blocks new submissions',
    () async {
      await host.configureAutomation({
        'item': {
          'id': 'fixture',
          'trigger': 'webhook',
          'goal': 'Check fixture',
        },
      });
      await host.trigger('fixture', 'delivery-1');
      await host.trigger('fixture', 'delivery-1');
      expect(host.tasks.length, 1);
      expect(host.tasks.values.single['state'], 'awaitingApproval');
      await host.configureAutomation({
        'item': {
          'id': 'fixture',
          'trigger': 'webhook',
          'goal': 'Check fixture',
          'paused': true,
        },
      });
      await expectLater(
        host.trigger('fixture', 'delivery-2'),
        throwsStateError,
      );
    },
  );

  test(
    'failed durable append does not publish task or poison future writes',
    () async {
      await Directory('${host.directory.path}/events.jsonl').create();
      await expectLater(
        host.submit({'id': 'failed', 'command': 'no'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(host.tasks, isEmpty);
      await Directory('${host.directory.path}/events.jsonl').delete();
      await host.submit({'id': 'failed', 'command': 'no'});
      expect(host.tasks['failed']!['state'], 'awaitingApproval');
    },
  );

  test('competing tasks reserve workspace before process spawn', () async {
    final command = Platform.isWindows ? 'Start-Sleep -Seconds 2' : 'sleep 2';
    await host.submit({'id': 'first', 'command': command});
    await host.submit({'id': 'second', 'command': command});
    await host.approve('first');
    await host.approve('second');
    expect(host.tasks['second']!['state'], 'queued');
    await host.stop('second');
    await host.stop('first');
    await until(() => host.tasks['first']!['state'] == 'stopped');
    expect(host.tasks['second']!['state'], 'stopped');
  });

  test('stop cancels model request and rejects late continuation', () async {
    final model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final entered = Completer<void>();
    model.listen((request) async {
      await request.drain<void>();
      entered.complete();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'late'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      } catch (_) {}
    });
    host.modelUrl = 'http://127.0.0.1:${model.port}';
    host.modelName = 'fixture';
    await host.submit({'id': 'cancel', 'goal': 'Wait'});
    await host.approve('cancel');
    await entered.future;
    await host.stop('cancel');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(host.tasks['cancel']!['state'], 'stopped');
    expect(host.tasks['cancel']!['result'], isNull);
    await model.close(force: true);
  });

  test(
    'large artifact streams bytes while path traversal is refused',
    () async {
      final file = File('${host.workspace.path}/large.bin');
      final sink = file.openWrite();
      for (var i = 0; i < 9; i++) {
        sink.add(List.filled(1024 * 1024, 42));
      }
      await sink.close();
      await host.listen();
      final client = HttpClient();
      var request = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${host.port}/v1/artifact?download=1&path=large.bin',
        ),
      );
      request.headers.set(
        'Authorization',
        'Bearer test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      );
      var bytes = 0;
      await for (final chunk in await request.close()) {
        bytes += chunk.length;
      }
      expect(bytes, 9 * 1024 * 1024);
      request = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${host.port}/v1/artifact?path=..%2Fcredential',
        ),
      );
      request.headers.set(
        'Authorization',
        'Bearer test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      );
      expect((await request.close()).statusCode, 400);
      client.close(force: true);
    },
  );

  test(
    'damaged trailing journal preserves bytes and refuses startup',
    () async {
      await host.submit({'id': 'preserved', 'command': 'never dispatched'});
      await host.close();
      final journal = File('${host.directory.path}/events.jsonl');
      await journal.writeAsString(
        '{"task":',
        mode: FileMode.append,
        flush: true,
      );
      final bytes = await journal.readAsBytes();
      host = RemoteHost(host.directory, host.workspace);
      await expectLater(host.open(), throwsStateError);
      expect(await journal.readAsBytes(), bytes);
    },
  );

  test(
    'bad-auth rate limit stays bounded without blocking valid owner control',
    () async {
      await host.listen();
      final client = HttpClient();
      for (var i = 0; i < 6; i++) {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${host.port}/v1/tasks'),
        );
        final response = await request.close();
        expect(response.statusCode, i == 5 ? 429 : 401);
        await response.drain<void>();
      }
      final valid = await client.getUrl(
        Uri.parse('http://127.0.0.1:${host.port}/v1/tasks'),
      );
      valid.headers.set(
        'Authorization',
        'Bearer test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      );
      expect((await valid.close()).statusCode, 200);
      client.close(force: true);
    },
  );

  test(
    'damaged credential cannot become empty bearer authorization; explicit rotation preserves jobs',
    () async {
      await host.submit({'id': 'preserve-auth', 'command': 'never dispatched'});
      final data = host.directory, work = host.workspace;
      await host.close();
      final credential = File('${data.path}/credential');
      await credential.writeAsString('', flush: true);
      host = RemoteHost(data, work);
      await expectLater(host.open(), throwsStateError);
      expect(await credential.readAsString(), '');
      await host.close();
      host = RemoteHost(data, work);
      await host.open(rotatePairing: true);
      expect(host.token!.length, greaterThanOrEqualTo(32));
      expect(host.tasks['preserve-auth']!['state'], 'awaitingApproval');
    },
  );

  test('expired credentials and revoked pairing cannot authorize', () async {
    await host.listen();
    final client = HttpClient();
    host.credentialExpiresAt = DateTime.now().subtract(
      const Duration(seconds: 1),
    );
    var request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}/v1/tasks'),
    );
    request.headers.set(
      'Authorization',
      'Bearer test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    );
    expect((await request.close()).statusCode, 401);
    await host.rotateCredential();
    request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${host.port}/v1/tasks'),
    );
    request.headers.set(
      'Authorization',
      'Bearer test-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    );
    expect((await request.close()).statusCode, 401);
    client.close(force: true);
  });

  test(
    'independent agent sessions are not globally capped by workspace commands',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        await release.future;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'Independent result'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${server.port}';
      host.modelName = 'fixture';
      await host.submit({'id': 'a', 'goal': 'Independent A'});
      await host.submit({'id': 'b', 'goal': 'Independent B'});
      await host.approve('a');
      await host.approve('b');
      await until(() => calls == 2);
      expect(
        host.tasks.values.every((task) => task['state'] == 'running'),
        true,
      );
      release.complete();
      await until(
        () => host.tasks.values.every((task) => task['state'] == 'completed'),
      );
      await server.close(force: true);
    },
  );

  test(
    'journal compaction restores identity and keeps monotonic cursors',
    () async {
      final journal = File('${host.directory.path}/events.jsonl');
      await journal.writeAsString('${' ' * (8 * 1024 * 1024)}\n');
      await host.submit({'id': 'retained', 'command': 'never dispatched'});
      expect(
        await File('${host.directory.path}/checkpoint.json').exists(),
        isTrue,
      );
      expect(await journal.length(), lessThan(8 * 1024 * 1024));
      await host.close();
      host = RemoteHost(host.directory, host.workspace);
      await host.open();
      expect(host.tasks['retained']!['state'], 'awaitingApproval');
      await host.submit({'id': 'next', 'command': 'never dispatched'});
      expect(host.events.last['cursor'], 2);
      await expectLater(
        host.approve('next', expectedVersion: 'stale-version'),
        throwsStateError,
      );
      expect(host.tasks['next']!['state'], 'awaitingApproval');
    },
  );

  test(
    'file trigger debounces burst and persists dedupe after restart',
    () async {
      final file = File('${host.workspace.path}/watched.txt');
      await file.writeAsString('initial');
      await host.configureAutomation({
        'item': {
          'id': 'watch',
          'trigger': 'file',
          'path': 'watched.txt',
          'goal': 'Inspect changed fixture',
        },
      });
      await until(() => host.automations['watch']!['lastSignature'] != null);
      await file.writeAsString('burst1');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await file.writeAsString('final burst content');
      await until(() => host.tasks.isNotEmpty);
      expect(host.tasks.length, 1);
      final task = host.tasks.values.single;
      expect((task['trigger'] as Map)['kind'], 'file');
      await host.close();
      host = RemoteHost(host.directory, host.workspace);
      await host.open();
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(host.tasks.length, 1);
    },
  );
}
