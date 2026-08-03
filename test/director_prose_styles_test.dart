import 'package:expert_chat/domain/story/director_prose_styles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mergeRequirements combines compatible styles and freeform', () {
    // jp_ln (perspective) + wuxia (ungrouped) + freeform are compatible.
    final text = DirectorProseStyle.mergeRequirements(
      styleIds: const ['jp_ln', 'wuxia'],
      freeform: '禁止早恋结局',
    );
    expect(text, contains('强制文风·日本轻小说'));
    expect(text, contains('强制文风·武侠'));
    expect(text, contains('其它硬性要求'));
    expect(text, contains('禁止早恋结局'));
  });

  test('toggleSelection enforces exclusive groups', () {
    var selected = <String>{};
    selected = DirectorProseStyle.toggleSelection(selected, 'jp_ln');
    selected = DirectorProseStyle.toggleSelection(selected, 'first_person');
    expect(selected, equals({'first_person'})); // drops jp_ln (same perspective)
    selected = DirectorProseStyle.toggleSelection(selected, 'wenyan');
    selected = DirectorProseStyle.toggleSelection(selected, 'web_novel');
    expect(selected.contains('wenyan'), isFalse);
    expect(selected, containsAll(['first_person', 'web_novel']));
  });

  test('mergeRequirements drops conflicting styles', () {
    final text = DirectorProseStyle.mergeRequirements(
      styleIds: const ['jp_ln', 'first_person', 'wenyan'],
      freeform: '',
    );
    // Last-wins within each exclusive group via sequential toggle.
    expect(text, contains('第一人称'));
    expect(text, isNot(contains('日本轻小说')));
    expect(text, contains('文言文'));
  });

  test('mergeRequirements ignores unknown ids', () {
    final text = DirectorProseStyle.mergeRequirements(
      styleIds: const ['nope'],
      freeform: '只要这句',
    );
    expect(text, contains('只要这句'));
    expect(text, isNot(contains('强制文风')));
  });

  test('presets cover requested families', () {
    final labels = DirectorProseStyle.presets.map((p) => p.label).toSet();
    expect(labels, containsAll(['日本轻小说', '古典章回', '文言文']));
  });

  test('jp_ln constraint encodes light-novel scene rules', () {
    final style = DirectorProseStyle.byId('jp_ln')!;
    expect(style.constraint, contains('「」'));
    expect(style.constraint, contains('对白'));
    expect(style.constraint, contains('一场戏'));
  });
}
