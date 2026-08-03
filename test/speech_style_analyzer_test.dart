import 'package:expert_chat/domain/speech/speech_style_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('analyzeSpeechStyle', () {
    test('happy text leans bright and upbeat', () {
      final style = analyzeSpeechStyle('太好了！恭喜你，真的好开心哈哈！');
      expect(style, contains('感情'));
      expect(
        style.contains('轻快') ||
            style.contains('笑') ||
            style.contains('兴奋') ||
            style.contains('明亮'),
        isTrue,
        reason: style,
      );
    });

    test('sad text leans soft and low', () {
      final style = analyzeSpeechStyle('对不起……我很难过，眼泪止不住。');
      expect(
        style.contains('感伤') ||
            style.contains('低回') ||
            style.contains('沉缓') ||
            style.contains('柔'),
        isTrue,
        reason: style,
      );
    });

    test('question text leans curious', () {
      final style = analyzeSpeechStyle('为什么会这样？难道是我弄错了？');
      expect(
        style.contains('疑惑') ||
            style.contains('上扬') ||
            style.contains('好奇') ||
            style.contains('探究'),
        isTrue,
        reason: style,
      );
    });

    test('empty text still returns a usable warm instruction', () {
      final style = analyzeSpeechStyle('   ');
      expect(style, isNotEmpty);
      expect(style, contains('朗读'));
    });
  });

  group('mergeSpeechStyleInstructions', () {
    test('design mode keeps persona first then emotion', () {
      final merged = mergeSpeechStyleInstructions(
        basePrompt: '元气少女人设',
        autoStyle: '本句更兴奋',
        designMode: true,
      );
      expect(merged.startsWith('元气少女人设'), isTrue);
      expect(merged, contains('本句情绪与演绎'));
      expect(merged, contains('本句更兴奋'));
    });

    test('non-design mode concatenates prompts', () {
      final merged = mergeSpeechStyleInstructions(
        basePrompt: '温柔一点',
        autoStyle: '稍快',
        designMode: false,
      );
      expect(merged, contains('温柔一点'));
      expect(merged, contains('稍快'));
    });
  });
}
