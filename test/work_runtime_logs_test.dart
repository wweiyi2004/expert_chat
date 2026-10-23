import 'dart:convert';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'diagnostics redact exact keys, authorization, tokens, data and URL paths',
    () {
      final safe = sanitizeRuntimeLogText(
        'key secret-from-profile; Bearer bearer-value; api_key="another-secret"; '
        'password=password-value https://user:pass@example.org/private/path?token=query-secret '
        'sk-1234567890 eyJabc.def.ghi data:image/png;base64,QUJDRA==',
        secrets: ['secret-from-profile'],
      );
      for (final secret in [
        'secret-from-profile',
        'bearer-value',
        'another-secret',
        'password-value',
        'user:pass',
        'private/path',
        'query-secret',
        '1234567890',
        'eyJabc',
        'QUJDRA',
      ]) {
        expect(safe, isNot(contains(secret)), reason: secret);
      }
      expect(safe, contains('https://example.org'));
      expect(
        runtimeLogHost('https://user:key@example.org:8443/private?key=secret'),
        'example.org:8443',
      );
      expect(
        sanitizeRuntimeLogText('x' * 5000).length,
        lessThanOrEqualTo(2049),
      );
    },
  );

  test(
    'retention bounds age, per-session count, global count and serialized size',
    () {
      final now = DateTime.now();
      WorkRuntimeLogEntry entry(
        int index,
        String conversation, {
        DateTime? at,
      }) => WorkRuntimeLogEntry(
        id: '$index',
        conversationId: conversation,
        timestamp: at ?? now.add(Duration(microseconds: index)),
        level: WorkRuntimeLogLevel.info,
        phase: 'request',
        status: 'completed',
        detail: 'x' * 50,
      );
      final logs = [
        entry(-1, 'old', at: now.subtract(const Duration(days: 8))),
        for (var i = 0; i < 10; i++) entry(i, 'a'),
        for (var i = 10; i < 15; i++) entry(i, 'b'),
      ];
      final kept = retainRuntimeLogs(
        logs,
        now: now,
        perConversation: 3,
        total: 5,
      );
      expect(kept.length, 5);
      expect(kept.where((e) => e.conversationId == 'a').map((e) => e.id), [
        '8',
        '9',
      ]);
      expect(kept.where((e) => e.conversationId == 'b').map((e) => e.id), [
        '12',
        '13',
        '14',
      ]);
      final bounded = retainRuntimeLogs(logs, now: now, maxBytes: 600);
      expect(
        utf8.encode(jsonEncode(bounded.map((e) => e.toJson()).toList())).length,
        lessThanOrEqualTo(600),
      );
    },
  );

  test(
    'corrupt persisted diagnostics do not block isolated sanitized logs and exports',
    () async {
      SharedPreferences.setMockInitialValues({
        WorkRuntimeLogs.storageKey: '{broken',
      });
      final prefs = await SharedPreferences.getInstance();
      ProviderContainer create() => ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      final first = create();
      final logger = first.read(workRuntimeLogsProvider.notifier);
      expect(first.read(workRuntimeLogsProvider), isEmpty);
      logger.add(
        conversationId: 'a',
        phase: 'request',
        status: 'failed',
        level: WorkRuntimeLogLevel.error,
        model: 'model-a',
        endpoint: 'https://user:key@provider.invalid/v1?key=sensitive',
        detail: 'client exception key-sensitive',
        secrets: ['key-sensitive'],
        httpStatus: 429,
        durationMs: 1200,
      );
      logger.add(
        conversationId: 'b',
        phase: 'tool',
        status: 'started',
        toolName: 'coding_read_file',
      );
      await logger.flush();
      final persisted = prefs.getString(WorkRuntimeLogs.storageKey)!;
      expect(persisted, isNot(contains('key-sensitive')));
      expect(persisted, isNot(contains('user:key')));
      expect(persisted, isNot(contains('/v1')));
      final exported = jsonDecode(logger.exportConversation('a')) as Map;
      expect(exported['conversationId'], 'a');
      expect(exported['httpStatus'], 429);
      expect(exported['host'], 'provider.invalid');
      first.dispose();
      await Future<void>.delayed(Duration.zero);
      final second = create();
      addTearDown(second.dispose);
      expect(second.read(workRuntimeLogsProvider).length, 2);
      final restored = second.read(workRuntimeLogsProvider.notifier);
      expect(
        restored.forConversation('a').single.detail,
        'client exception [redacted]',
      );
      await restored.clearConversation('a');
      expect(restored.forConversation('a'), isEmpty);
      expect(restored.forConversation('b').single.toolName, 'coding_read_file');
    },
  );

  test('one corrupt row does not discard valid sessions', () async {
    final now = DateTime.now();
    final valid = WorkRuntimeLogEntry(
      id: 'one',
      conversationId: 'a',
      timestamp: now,
      level: WorkRuntimeLogLevel.info,
      phase: 'session',
      status: 'running',
    );
    SharedPreferences.setMockInitialValues({
      WorkRuntimeLogs.storageKey: jsonEncode([
        {'bad': true},
        valid.toJson(),
      ]),
    });
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(workRuntimeLogsProvider).single.id, 'one');
  });
}
