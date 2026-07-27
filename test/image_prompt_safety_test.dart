import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/media/image_prompt_safety.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('characterPortrait uses card looks and stays SFW', () {
    final card = CharacterCard(
      name: '林晚',
      description: '黑长直，白衬衫，清秀',
      personality: '冷静',
    );
    final prompt = ImagePromptSafety.characterPortrait(
      card,
      userHint: 'soft smile, looking at viewer',
    );
    expect(prompt, contains('林晚'));
    expect(prompt, contains('黑长直'));
    expect(prompt, contains('soft smile'));
    expect(prompt, contains('safe for work'));
    expect(prompt, contains('no nsfw'));
  });

  test('characterPortrait strips sexual user hints and story smut', () {
    final card = CharacterCard(
      name: 'A',
      description: 'red coat, silver hair',
    );
    final prompt = ImagePromptSafety.characterPortrait(
      card,
      userHint: 'nude erotic sex 做爱 全裸 ahegao',
    );
    expect(prompt.toLowerCase(), isNot(contains('nude')));
    expect(prompt.toLowerCase(), isNot(contains('erotic')));
    expect(prompt, isNot(contains('做爱')));
    expect(prompt, isNot(contains('全裸')));
    expect(prompt, contains('red coat'));
    expect(prompt, contains(ImagePromptSafety.sfwSuffix.split(', ').first));
  });

  test('freeform scrubs R18 prose from dialogue illustration prompts', () {
    final prompt = ImagePromptSafety.freeform(
      '两人在床上激烈做爱，全裸纠缠，描写省略',
    );
    expect(prompt, isNot(contains('做爱')));
    expect(prompt, isNot(contains('全裸')));
    expect(prompt, contains('safe for work'));
  });
}
