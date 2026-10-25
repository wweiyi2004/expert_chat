import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:expert_chat/domain/remote/remote_host.dart';
import 'package:expert_chat/domain/tools/math/math_process.dart';

void main() {
  test(
    'authenticated real file/Git/math views remain workspace scoped',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'expert-remote-workspace-',
      );
      final work = await Directory('${fixture.path}/work').create();
      final host = RemoteHost(
        Directory('${fixture.path}/private'),
        work,
        token: 'fixture-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      );
      await host.open();
      await host.listen();
      final client = HttpClient();
      Future<Map> request(String path, [Map? body]) async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          Uri.parse('http://127.0.0.1:${host.port}/v1/$path'),
        );
        request.headers.set(
          'Authorization',
          'Bearer fixture-only-pairing-key-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
        );
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        return jsonDecode(await utf8.decoder.bind(await request.close()).join())
            as Map;
      }

      try {
        await File('${work.path}/fixture.txt').writeAsString('original\n');
        Future<void> git(List<String> arguments) async {
          final result = await Process.run(
            'git',
            arguments,
            workingDirectory: work.path,
          );
          expect(result.exitCode, 0, reason: result.stderr.toString());
        }

        await git(['init']);
        await git(['add', 'fixture.txt']);
        await git([
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@invalid.test',
          'commit',
          '-m',
          'fixture',
        ]);
        await File('${work.path}/fixture.txt').writeAsString('changed\n');
        expect((await request('files'))['entries'], isNotEmpty);
        expect(
          (await request('git?view=status'))['stdout'],
          contains('fixture.txt'),
        );
        expect((await request('git?view=log'))['stdout'], contains('fixture'));
        expect(
          (await request('git?view=diff'))['stdout'],
          contains('+changed'),
        );
        expect(
          (await request('files?path=..'))['error'],
          contains('escapes workspace'),
        );
        final script = await File('assets/math/toolkit.py').readAsString();
        host.mathExecutor = (arguments) async => jsonEncode(
          await executeMathScript(
            arguments,
            pythonExecutable: 'python',
            trustedScript: script,
          ),
        );
        final math = await request('tools/math', {
          'operation': 'exact',
          'expression': '1/3 + 1/6',
        });
        final result = jsonDecode(math['result'] as String) as Map;
        expect(result['ok'], true);
        expect(jsonEncode(result), contains('1/2'));
        await host.configureAutomation({
          'item': {
            'id': 'repo',
            'trigger': 'repository',
            'goal': 'Inspect fixture commit',
          },
        });
        final baselineDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (host.automations['repo']!['lastSignature'] == null &&
            DateTime.now().isBefore(baselineDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await git(['add', 'fixture.txt']);
        await git([
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@invalid.test',
          'commit',
          '-m',
          'changed fixture',
        ]);
        final triggerDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (host.tasks.isEmpty && DateTime.now().isBefore(triggerDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(host.tasks.length, 1);
        expect(
          (host.tasks.values.single['trigger'] as Map)['kind'],
          'repository',
        );
      } finally {
        client.close(force: true);
        await host.close();
        await fixture.delete(recursive: true);
      }
    },
  );
}
