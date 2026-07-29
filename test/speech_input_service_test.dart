import 'package:expert_chat/domain/speech/speech_input_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mergeSpeechIntoDraft', () {
    test(
      'inserts Chinese transcript at the cursor without artificial spaces',
      () {
        expect(
          mergeSpeechIntoDraft(before: '请帮我', transcript: '写一封邮件', after: '谢谢'),
          '请帮我写一封邮件谢谢',
        );
      },
    );

    test('keeps English words separated', () {
      expect(
        mergeSpeechIntoDraft(
          before: 'Please',
          transcript: 'write an email',
          after: 'today',
        ),
        'Please write an email today',
      );
    });

    test('does not duplicate existing whitespace', () {
      expect(
        mergeSpeechIntoDraft(before: '开头 ', transcript: '中间', after: '\n结尾'),
        '开头 中间\n结尾',
      );
    });
  });

  test('speech errors have actionable Chinese messages', () {
    expect(
      const SpeechInputFailure(
        code: 'error_permission',
        permanent: true,
      ).userMessage,
      contains('系统设置'),
    );
    expect(
      const SpeechInputFailure(
        code: 'error_network_timeout',
        permanent: false,
      ).userMessage,
      contains('网络'),
    );
    expect(
      const SpeechInputFailure(
        code: 'error_no_match',
        permanent: false,
      ).userMessage,
      contains('没有听清'),
    );
  });
}
