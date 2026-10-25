import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:expert_chat/domain/remote/remote_host.dart';
import 'package:expert_chat/domain/remote/remote_policy.dart';

void main() {
  late Directory fixture;
  late RemoteHost host;
  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('expert-policy-');
    final work = await Directory('${fixture.path}/work').create();
    host = RemoteHost(
      Directory('${fixture.path}/private'),
      work,
      token: 'fixture-token-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
    );
    await host.open();
  });
  tearDown(() async {
    await host.close();
    await fixture.delete(recursive: true);
  });
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for host policy');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  String command(String path) =>
      Platform.isWindows ? "Add-Content $path 'once'" : 'echo once >> $path';
  String sse(Map message, {bool tool = false}) =>
      'data: ${jsonEncode({
        'choices': [
          {'delta': message, 'finish_reason': tool ? 'tool_calls' : 'stop'},
        ],
      })}\n\ndata: [DONE]\n\n';

  test(
    'fixed wall clock still produces unique CAS revisions for consecutive commands',
    () async {
      final data = host.directory, work = host.workspace;
      await host.close();
      host = RemoteHost(data, work, clock: () => DateTime.utc(2026, 1, 1));
      await host.open();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          sse({
            'tool_calls': [
              {
                'index': 0,
                'id': 'step-$calls',
                'type': 'function',
                'function': {
                  'name': 'shell',
                  'arguments': jsonEncode({
                    'command': command('step-$calls.txt'),
                  }),
                },
              },
            ],
          }, tool: true),
        );
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${server.port}';
      host.modelName = 'fixture';
      await host.submit({'id': 'clock', 'goal': 'Fixture two explicit steps'});
      await host.approve('clock');
      await until(
        () =>
            host.tasks['clock']!['state'] == 'awaitingApproval' &&
            host.tasks['clock']!['pendingCommand'] != null,
      );
      final oldVersion = host.tasks['clock']!['version'] as String;
      final timestamp = host.tasks['clock']!['updatedAt'];
      await host.approve('clock', expectedVersion: oldVersion);
      await until(
        () => calls == 2 && host.tasks['clock']!['state'] == 'awaitingApproval',
      );
      expect(host.tasks['clock']!['updatedAt'], timestamp);
      expect(host.tasks['clock']!['version'], isNot(oldVersion));
      await expectLater(
        host.approve('clock', expectedVersion: oldVersion),
        throwsStateError,
      );
      expect(await File('${work.path}/step-2.txt').exists(), false);
      await host.stop('clock');
      await server.close(force: true);
    },
  );

  test(
    'restart model/account changes cannot replay pending command or forward native history',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          calls == 1
              ? sse({
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'pinned',
                      'type': 'function',
                      'function': {
                        'name': 'shell',
                        'arguments': jsonEncode({
                          'command': command('pinned.txt'),
                        }),
                      },
                    },
                  ],
                }, tool: true)
              : sse({'content': 'Verified pinned result'}),
        );
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      host.modelUrl = url;
      host.modelName = 'original';
      await host.submit({'id': 'pinned', 'goal': 'Fixture original model'});
      await host.approve('pinned');
      await until(
        () =>
            host.tasks['pinned']!['state'] == 'awaitingApproval' &&
            host.tasks['pinned']!['pendingCommand'] != null,
      );
      final data = host.directory, work = host.workspace;
      await host.close();
      host = RemoteHost(data, work);
      host.modelUrl = url;
      host.modelName = 'changed';
      await host.open();
      await expectLater(
        host.approve(
          'pinned',
          expectedVersion: host.tasks['pinned']!['version'] as String,
        ),
        throwsStateError,
      );
      expect(calls, 1);
      expect(await File('${work.path}/pinned.txt').exists(), false);
      host.modelName = 'original';
      host.modelKey = 'fixture-changed-account';
      await expectLater(
        host.approve(
          'pinned',
          expectedVersion: host.tasks['pinned']!['version'] as String,
        ),
        throwsStateError,
      );
      host.modelKey = null;
      host.modelFormat = 'anthropicMessages';
      await expectLater(
        host.approve(
          'pinned',
          expectedVersion: host.tasks['pinned']!['version'] as String,
        ),
        throwsStateError,
      );
      host.modelFormat = 'openAiCompatible';
      await host.approve(
        'pinned',
        expectedVersion: host.tasks['pinned']!['version'] as String,
      );
      await until(() => host.tasks['pinned']!['state'] == 'completed');
      expect(calls, 2);
      expect((await File('${work.path}/pinned.txt').readAsLines()).length, 1);
      await server.close(force: true);
    },
  );

  test(
    'Stop at approved budget boundary does not start a late model round',
    () async {
      final data = host.directory, work = host.workspace;
      await host.close();
      var scheduled = false;
      host = RemoteHost(
        data,
        work,
        clock: () {
          if (!scheduled && host.tasks['race']?['roundLimit'] == 2) {
            scheduled = true;
            scheduleMicrotask(() => unawaited(host.stop('race')));
          }
          return DateTime.now();
        },
      );
      host.allowedPolicies.add('full');
      host.allowAutoBudgetExtension = true;
      host.maxRounds = 1;
      host.roundCeiling = 2;
      host.budgetExtensionRounds = 1;
      host.reviewer = (_, _, _, _) async =>
          const ApprovalVerdict('approve', 'Bounded fixture');
      await host.open();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          sse({
            'tool_calls': [
              {
                'index': 0,
                'id': 'read-$calls',
                'type': 'function',
                'function': {
                  'name': 'deliver_files',
                  'arguments': '{"paths":[]}',
                },
              },
            ],
          }, tool: true),
        );
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${server.port}';
      host.modelName = 'fixture';
      await host.submit({
        'id': 'race',
        'goal': 'Readonly boundary fixture',
        'policy': 'full',
        'roundLimit': 1,
        'autoBudgetExtension': true,
      });
      await until(() => host.tasks['race']!['state'] == 'stopped');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(host.tasks['race']!['state'], 'stopped');
      expect(calls, 1);
      await server.close(force: true);
    },
  );

  test(
    'request is default; full needs host opt-in and duplicate never auto-dispatches again',
    () async {
      await host.submit({'id': 'default', 'command': command('default.txt')});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.tasks['default']!['state'], 'awaitingApproval');
      expect(await File('${host.workspace.path}/default.txt').exists(), false);
      await expectLater(
        host.submit({
          'id': 'denied',
          'command': command('denied.txt'),
          'policy': 'full',
        }),
        throwsArgumentError,
      );
      host.allowedPolicies.add('full');
      final body = {
        'id': 'full',
        'command': command('full.txt'),
        'policy': 'full',
        'roundLimit': 3,
      };
      await host.submit(body);
      await until(() => host.tasks['full']!['state'] == 'completed');
      await host.submit(body);
      expect(
        (await File('${host.workspace.path}/full.txt').readAsLines()).length,
        1,
      );
      await expectLater(
        host.submit({...body, 'roundLimit': 4}),
        throwsStateError,
      );
      await expectLater(
        host.submit({...body, 'autoBudgetExtension': true}),
        throwsStateError,
      );
    },
  );

  test(
    'assisted rejection, unknown and stopped late approval remain human-owned',
    () async {
      host.allowedPolicies.add('assisted');
      for (final verdict in ['reject', 'unknown']) {
        host.reviewer = (_, _, _, _) async =>
            ApprovalVerdict(verdict, 'Fixture review');
        await host.submit({
          'id': verdict,
          'command': command('$verdict.txt'),
          'policy': 'assisted',
        });
        await until(() => host.tasks[verdict]!['approvalReview'] != null);
        expect(host.tasks[verdict]!['state'], 'awaitingApproval');
        expect(
          await File('${host.workspace.path}/$verdict.txt').exists(),
          false,
        );
      }
      final review = Completer<ApprovalVerdict>();
      var entered = false;
      host.reviewer = (_, _, _, _) {
        entered = true;
        return review.future;
      };
      await host.submit({
        'id': 'late',
        'command': command('late.txt'),
        'policy': 'assisted',
      });
      await until(() => entered);
      await host.stop('late');
      review.complete(const ApprovalVerdict('approve', 'Late result'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.tasks['late']!['state'], 'stopped');
      expect(await File('${host.workspace.path}/late.txt').exists(), false);
    },
  );

  test(
    'real assisted reviewer has no tools and invalid structured verdict never grants',
    () async {
      host.allowedPolicies.add('assisted');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final input =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(input['tools'], isNull);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          sse({
            'content':
                '{"verdict":"approve","reason":"fixture","unexpected_grant":true}',
          }),
        );
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${server.port}';
      host.modelName = 'fixture';
      await host.submit({
        'id': 'strict',
        'command': command('strict.txt'),
        'policy': 'assisted',
      });
      await until(() => host.tasks['strict']!['approvalReview'] != null);
      expect(host.tasks['strict']!['approvalReview']['verdict'], 'unknown');
      expect(await File('${host.workspace.path}/strict.txt').exists(), false);
      await server.close(force: true);
    },
  );

  test(
    'manual versioned round extension continues original history without repeating shell effect',
    () async {
      host.allowedPolicies.add('full');
      host.maxRounds = 1;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var calls = 0;
      server.listen((request) async {
        final input =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        calls++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        if (calls == 1) {
          request.response.write(
            sse({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'write-1',
                  'type': 'function',
                  'function': {
                    'name': 'shell',
                    'arguments': jsonEncode({'command': command('budget.txt')}),
                  },
                },
              ],
            }, tool: true),
          );
        } else {
          expect((input['messages'] as List).last['role'], 'tool');
          request.response.write(sse({'content': 'Verified original result'}));
        }
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${server.port}';
      host.modelName = 'fixture';
      final body = {
        'id': 'budget',
        'goal': 'Write fixture once and verify',
        'policy': 'full',
        'roundLimit': 1,
      };
      await host.submit(body);
      await until(() => host.tasks['budget']!['state'] == 'waiting_budget');
      expect(calls, 1);
      await expectLater(
        host.extendBudget('budget', 1, expectedVersion: 'stale'),
        throwsStateError,
      );
      await host.extendBudget(
        'budget',
        1,
        expectedVersion: host.tasks['budget']!['version'] as String,
      );
      await until(() => host.tasks['budget']!['state'] == 'completed');
      expect(calls, 2);
      expect(
        (await File('${host.workspace.path}/budget.txt').readAsLines()).length,
        1,
      );
      await host.submit(
        body,
      ); // original submission identity is immutable after top-up
      await expectLater(
        host.extendBudget(
          'budget',
          1,
          expectedVersion: host.tasks['budget']!['version'] as String,
        ),
        throwsStateError,
      );
      await server.close(force: true);
    },
  );

  test(
    'automatic round review obeys owner ceiling/count and defaults off',
    () async {
      await expectLater(
        host.submit({
          'id': 'not-enabled',
          'goal': 'Fixture',
          'autoBudgetExtension': true,
        }),
        throwsArgumentError,
      );
      host.allowedPolicies.add('full');
      host.allowAutoBudgetExtension = true;
      host.roundCeiling = 2;
      host.maxRounds = 1;
      host.budgetExtensionRounds = 1;
      host.maxBudgetReviews = 1;
      var reviews = 0, calls = 0;
      host.reviewer = (_, _, purpose, _) async {
        expect(purpose, 'budget');
        reviews++;
        return const ApprovalVerdict(
          'approve',
          'One bounded useful continuation',
        );
      };
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          sse({
            'tool_calls': [
              {
                'index': 0,
                'id': 'read-$calls',
                'type': 'function',
                'function': {
                  'name': 'deliver_files',
                  'arguments': '{"paths":[]}',
                },
              },
            ],
          }, tool: true),
        );
        await request.response.close();
      });
      host.modelUrl = 'http://127.0.0.1:${server.port}';
      host.modelName = 'fixture';
      await host.submit({
        'id': 'bounded',
        'goal': 'Fixture readonly loop',
        'policy': 'full',
        'roundLimit': 1,
        'autoBudgetExtension': true,
      });
      await until(() => host.tasks['bounded']!['state'] == 'waiting_budget');
      expect(reviews, 1);
      expect(calls, 2);
      expect(host.tasks['bounded']!['roundLimit'], 2);
      await expectLater(
        host.extendBudget(
          'bounded',
          1,
          expectedVersion: host.tasks['bounded']!['version'] as String,
        ),
        throwsArgumentError,
      );
      await host.stop('bounded');
      expect(host.tasks['bounded']!['state'], 'stopped');
      await server.close(force: true);
    },
  );

  test(
    'private journal cannot be rebound to a different project on restart',
    () async {
      await host.submit({'id': 'bound', 'command': 'never dispatched'});
      final data = host.directory;
      await host.close();
      final other = await Directory('${fixture.path}/other').create();
      host = RemoteHost(data, other);
      await expectLater(host.open(), throwsStateError);
      expect(
        await File('${data.path}/workspace-binding').readAsString(),
        isNot(other.path),
      );
    },
  );
}
