import 'package:expert_chat/features/story/story_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clearing author note preserves the original story premise', () {
    const previous =
        'AI 扮演全部角色，用户是导演。\n\n'
        '【故事原始情节】（核心基调与事件不可擅自改写）\n'
        '夜车永远无法抵达终点。';

    final protected = protectStoryAuthorNote(previous: previous, edited: '');

    expect(protected, contains('【故事原始情节】'));
    expect(protected, contains('夜车永远无法抵达终点'));
  });

  test('new text is appended without dropping protected setup blocks', () {
    const previous =
        '【硬性创作约束】（不可违背）\n禁止超自然\n\n'
        '【故事原始情节】（核心基调与事件不可擅自改写）\n现实悬疑。';

    final protected = protectStoryAuthorNote(
      previous: previous,
      edited: '节奏再慢一些',
    );

    expect(protected, contains('禁止超自然'));
    expect(protected, contains('现实悬疑'));
    expect(protected, contains('【情节面板补充】\n节奏再慢一些'));
  });

  test('keeping one protected header does not erase the other', () {
    const previous =
        '【硬性创作约束】（不可违背）\n禁止超自然\n\n'
        '【故事原始情节】（核心基调与事件不可擅自改写）\n现实悬疑。';

    final protected = protectStoryAuthorNote(
      previous: previous,
      edited: '【硬性创作约束】（不可违背）\n禁止超自然；禁止巧合破案',
    );

    expect(protected, contains('禁止巧合破案'));
    expect(protected, contains('【故事原始情节】'));
    expect(protected, contains('现实悬疑'));
  });
}
