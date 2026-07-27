import 'package:expert_chat/domain/story/director_prose_styles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mergeRequirements combines styles and freeform', () {
    final text = DirectorProseStyle.mergeRequirements(
      styleIds: const ['jp_ln', 'wenyan'],
      freeform: '禁止早恋结局',
    );
    expect(text, contains('强制文风·日本轻小说'));
    expect(text, contains('强制文风·文言文'));
    expect(text, contains('其它硬性要求'));
    expect(text, contains('禁止早恋结局'));
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
}
