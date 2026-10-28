import 'package:test/test.dart';
import 'package:expert_chat/domain/host/terminal_output.dart';

void main() {
  test('output cursors recover missed chunks and reset only when required', () {
    final output = HostTerminalOutput();
    output.add('中文\x1b[31m');
    final first = output.read(0, -1);
    expect(first['reset'], isTrue);
    output.add('next');
    final next = output.read(
      first['cursor'] as int,
      first['generation'] as int,
    );
    expect(next['text'], 'next');
    expect(next['reset'], isFalse);
    expect(
      output.read(first['cursor'] as int, first['generation'] as int)['text'],
      'next',
    );
    output.reset();
    output.add('new shell');
    expect(
      output.read(next['cursor'] as int, next['generation'] as int)['reset'],
      isTrue,
    );
  });
  test('slow clients receive a bounded reset with truncation disclosure', () {
    final output = HostTerminalOutput();
    for (var i = 0; i < 200; i++) {
      output.add('x' * 16384);
    }
    final result = output.read(0, 0);
    expect(result['reset'], isTrue);
    expect(result['truncated'], isTrue);
    expect((result['text'] as String).length, lessThanOrEqualTo(32 * 16384));
  });
}
