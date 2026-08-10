import 'package:expert_chat/domain/story/story_constraint_compiler.dart';
import 'package:expert_chat/domain/story/story_generation_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StoryConstraintCompiler', () {
    test('keeps each persistent source once with a typed heading', () {
      final value = StoryConstraintCompiler.compile(
        premise: '雾港夜车必须在黎明前返航。',
        requirements: '【全书硬约束】\n禁止超自然。',
        persistentNote: '真相揭晓前保持克制。',
      );

      expect('禁止超自然。'.allMatches(value), hasLength(1));
      expect(value, contains('【创作约束】'));
      expect(value, contains('【长期导演备注】'));
      expect(value, contains('【故事基准】'));
    });

    test('deduplicates identical sources', () {
      final value = StoryConstraintCompiler.compile(
        premise: '唯一规则',
        requirements: '唯一规则',
      );
      expect('唯一规则'.allMatches(value), hasLength(1));
    });
  });

  group('StoryGenerationIntentResolver', () {
    test('routes planning and consultation away from prose', () {
      expect(
        StoryGenerationIntentResolver.fromUserText('/改大纲 把高潮提前'),
        StoryGenerationIntent.revisePlan,
      );
      expect(
        StoryGenerationIntentResolver.fromUserText('问导演助手：这里拖沓吗？'),
        StoryGenerationIntent.consult,
      );
      expect(StoryGenerationIntent.revisePlan.writesProse, isFalse);
    });

    test('keeps scene actions explicit', () {
      expect(
        StoryGenerationIntentResolver.fromUserText('（导演：写下一场）'),
        StoryGenerationIntent.nextScene,
      );
      expect(
        StoryGenerationIntentResolver.fromUserText('（导演：续写当前场）'),
        StoryGenerationIntent.continueScene,
      );
    });
  });
}
