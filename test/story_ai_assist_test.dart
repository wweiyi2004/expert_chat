import 'package:expert_chat/domain/story/story_ai_assist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractJsonObject', () {
    test('parses plain json', () {
      final m = extractJsonObjectForTest('{"name":"林晚","description":"剑客"}');
      expect(m?['name'], '林晚');
      expect(m?['description'], '剑客');
    });

    test('strips markdown fences', () {
      final m = extractJsonObjectForTest('''
```json
{"title":"王都","keys":["王都","帝都"],"alwaysOn":false}
```
''');
      expect(m?['title'], '王都');
      expect(m?['keys'], isA<List>());
    });

    test('finds object inside prose', () {
      final m = extractJsonObjectForTest(
        '好的，如下：{"name":"阿宁","personality":"温柔"} 完毕',
      );
      expect(m?['name'], '阿宁');
    });
  });

  group('drafts', () {
    test('CharacterCardDraft.fromJsonMap', () {
      final d = CharacterCardDraft.fromJsonMap({
        'name': '  林晚  ',
        'firstMes': '你好',
      });
      expect(d?.name, '林晚');
      expect(d?.firstMes, '你好');
      final card = d!.toCard();
      expect(card.name, '林晚');
      expect(card.firstMes, '你好');
    });

    test('WorldInfoDraft.fromJsonMap keys list', () {
      final d = WorldInfoDraft.fromJsonMap({
        'title': '魔法学',
        'keys': ['魔法', '法术'],
        'content': '……',
        'alwaysOn': true,
        'priority': 10,
      });
      expect(d?.keys, ['魔法', '法术']);
      expect(d?.alwaysOn, isTrue);
      final entry = d!.toEntry();
      expect(entry.title, '魔法学');
      expect(entry.priority, 10);
    });
  });
}
