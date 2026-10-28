import 'dart:async';
import 'dart:convert';
import 'package:expert_chat/domain/research/command_output_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('small output remains exact across packet boundaries', () {
    final out = CommandOutputBuffer(maxChars: 16);
    for (final part in ['one', '\n', '二', '🙂', 'done']) {
      out.add(part);
    }
    expect(out.text, 'one\n二🙂done');
    expect(out.truncated, false);
  });
  test('large output retains bounded beginning and final errors', () {
    final out = CommandOutputBuffer(maxChars: 120);
    out.add('START\n');
    for (var i = 0; i < 10000; i++) {
      out.add('irrelevant log line\n');
    }
    out.add('FINAL ERROR\n');
    expect(out.retainedChars, lessThanOrEqualTo(120));
    expect(out.text, startsWith('START\n'));
    expect(out.text, endsWith('FINAL ERROR\n'));
    expect(out.text, contains('已省略中间'));
  });
  test('head/tail cuts keep Unicode valid and preserve packet order', () {
    final out = CommandOutputBuffer(maxChars: 8);
    out.add('a');
    out.add('🙂');
    out.add('b');
    expect(out.text, 'a🙂b');
    out.add('🙂' * 100);
    out.add('末🙂');
    expect(out.text, endsWith('末🙂'));
    expect(utf8.decode(utf8.encode(out.text)), out.text);
  });
  testWidgets('UI output batches packets and flushes the final tail', (
    tester,
  ) async {
    final values = <(String, bool)>[];
    final live = CommandOutputBatch((text, error) => values.add((text, error)));
    for (var i = 0; i < 10000; i++) {
      live.add('stdout\n', false);
      live.add('stderr\n', true);
    }
    expect(values, isEmpty);
    await tester.pump(const Duration(milliseconds: 80));
    expect(values.length, 2);
    expect(values.every((v) => v.$1.length < 32500), true);
    live.add('LAST LINE', false);
    live.flush();
    expect(values.last.$1, 'LAST LINE');
  });
  test(
    'incremental decoder preserves split UTF8 and yields to event loop',
    () async {
      final bytes = utf8.encode('中文🙂');
      final text = await decodeCommandOutput(
        Stream.fromIterable([
          bytes.sublist(0, 2),
          bytes.sublist(2, 7),
          bytes.sublist(7),
        ]),
      ).join();
      expect(text, '中文🙂');
      var heartbeat = false;
      final timer = Timer(Duration.zero, () => heartbeat = true);
      await decodeCommandOutput(
        Stream.fromIterable(List.filled(1000, List.filled(1024, 65))),
      ).drain<void>();
      expect(heartbeat, true);
      timer.cancel();
    },
  );
}
