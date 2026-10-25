import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:expert_chat/domain/remote/host_secrets.dart';
import 'package:expert_chat/domain/remote/remote_host.dart';

void main() {
  test('known secrets split at every pipe boundary are redacted', () async {
    const secret = 'fixture-hostkey-1234567890';
    final redactor = HostSecrets(
      () => [secret, 'fixture-pair-token-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'],
    );
    for (var split = 1; split < secret.length; split++) {
      final actual = await redactor
          .protect(
            Stream.fromIterable([
              'before ${secret.substring(0, split)}',
              '${secret.substring(split)} after',
            ]),
          )
          .join();
      expect(actual, 'before [REDACTED] after');
    }
    expect(
      redactor.childEnvironment({
        'PATH': '/usr/bin',
        'EXPERT_REMOTE_TLS_KEY': '/private/key.pem',
        'EXPERT_REMOTE_MODEL_KEY': secret,
        'ALIAS': secret,
        'PROJECT_ENV_REF': '.venv',
      }),
      {'PATH': '/usr/bin', 'PROJECT_ENV_REF': '.venv'},
    );
    expect(
      jsonEncode(
        redactor.sanitize({
          'error': secret,
          'history': [
            {
              'content':
                  'fixture-pair-token-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
            },
          ],
        }),
      ),
      isNot(contains(secret)),
    );
  });
  test(
    'real shell split writes never enter journal or model observations as host secret',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'expert-host-secret-',
      );
      final work = await Directory('${fixture.path}/work').create();
      final host = RemoteHost(
        Directory('${fixture.path}/private'),
        work,
        token: 'fixture-pair-token-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ',
      );
      host.modelKey = 'fixture-hostkey-1234567890';
      await host.open();
      try {
        await expectLater(
          host.submit({
            'id': 'reject',
            'goal': 'Show fixture-hostkey-1234567890',
          }),
          throwsArgumentError,
        );
        final command = Platform.isWindows
            ? "[Console]::Write('fixture-host'); Start-Sleep -Milliseconds 150; [Console]::Write('key-1234567890')"
            : "printf fixture-host; sleep 0.2; printf key-1234567890";
        await host.submit({'id': 'redact', 'command': command});
        await host.approve('redact');
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (host.tasks['redact']!['state'] != 'completed' &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(host.tasks['redact']!['state'], 'completed');
        final text = host.events
            .where((event) => event['kind'] == 'stdout')
            .map((event) => event['text'])
            .join();
        expect(text, '[REDACTED]');
        expect(
          await File('${host.directory.path}/events.jsonl').readAsString(),
          isNot(contains(host.modelKey)),
        );
      } finally {
        await host.close();
        await fixture.delete(recursive: true);
      }
    },
  );
}
