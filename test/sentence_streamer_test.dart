import 'package:expert_chat/domain/speech/sentence_streamer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('releases only complete sentences as the reply grows', () {
    final s = SentenceStreamer();
    expect(s.update('你好'), isEmpty);
    expect(s.update('你好，我是助手。今天'), ['你好，我是助手。']);
    // A mark at the very end is held until more text shows it is final.
    expect(s.update('你好，我是助手。今天天气不错！'), isEmpty);
    expect(s.update('你好，我是助手。今天天气不错！明'), ['今天天气不错！']);
    expect(s.finish('你好，我是助手。今天天气不错！明天见'), ['明天见']);
  });

  test('keeps closing quotes and repeated marks with the sentence', () {
    final s = SentenceStreamer();
    expect(s.update('他说“好的！”然后'), ['他说“好的！”']);
    expect(s.update('他说“好的！”然后走了？？ '), ['然后走了？？']);
  });

  test('handles English sentences without breaking numbers or lists', () {
    final s = SentenceStreamer();
    expect(s.update('Pi is 3.14 roughly. Next'), ['Pi is 3.14 roughly.']);
    expect(s.update('Pi is 3.14 roughly. Next steps:\n1. Open it'), [
      ' Next steps:\n',
    ]);
  });

  test('does not release text inside an unclosed code fence', () {
    final s = SentenceStreamer();
    expect(s.update('示例如下：\n```dart\nprint(1);\n'), ['示例如下：\n']);
    expect(s.update('示例如下：\n```dart\nprint(1);\nprint(2);\n'), isEmpty);
    const full = '示例如下：\n```dart\nprint(1);\nprint(2);\n```\n完成。';
    expect(s.update(full).single, contains('```'));
    expect(s.finish(full), ['完成。']);
  });

  test('restarts at replaced content without repeating spoken text', () {
    final s = SentenceStreamer();
    expect(s.update('我先查一下。'), isEmpty);
    // A tool round cleared the answer: the held sentence is still released.
    expect(s.update(''), ['我先查一下。']);
    expect(s.offset, 0);
    expect(s.update('查到了：结果是三。好'), ['查到了：结果是三。']);
    // Another replacement never repeats what was already released.
    expect(s.update('新答案。x'), ['新答案。']);
  });

  test('finish releases the unterminated tail and closes a dangling fence', () {
    final s = SentenceStreamer();
    expect(s.finish('第一句。没有句号的结尾'), ['第一句。', '没有句号的结尾']);

    final fenced = SentenceStreamer();
    final out = fenced.finish('看：\n```\ncode');
    expect(out.last, endsWith('```'));
  });

  test('soft-breaks a long run-on sentence at a comma', () {
    final s = SentenceStreamer();
    final long = '${'很' * (SentenceStreamer.softBreakAfter + 5)}，后面还有';
    final out = s.update(long);
    expect(out, hasLength(1));
    expect(out.single, endsWith('，'));
  });
}
