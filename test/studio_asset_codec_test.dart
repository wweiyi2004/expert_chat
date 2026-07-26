import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/story/studio_asset_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = StudioAssetCodec();

  group('character codec', () {
    test('round-trips a single card and mints a new id on import', () {
      final original = CharacterCard(
        name: '林晚',
        description: '剑客',
        personality: '冷淡',
        scenario: '客栈',
        firstMes: '……有事？',
        exampleDialogs: '{{user}}: 你好\n{{char}}: 嗯。',
        systemPrompt: '少说话',
      );
      final json = codec.encodeCharacter(original);
      final imported = codec.decodeCharacters(json).single;
      expect(imported.id, isNot(original.id));
      expect(imported.name, original.name);
      expect(imported.description, original.description);
      expect(imported.personality, original.personality);
      expect(imported.scenario, original.scenario);
      expect(imported.firstMes, original.firstMes);
      expect(imported.exampleDialogs, original.exampleDialogs);
      expect(imported.systemPrompt, original.systemPrompt);
    });

    test('accepts SillyTavern-style field aliases', () {
      const raw = '''
{
  "name": "Zero",
  "description": "clone",
  "first_mes": "……",
  "mes_example": "hi",
  "system_prompt": "stay calm"
}
''';
      final card = codec.decodeCharacters(raw).single;
      expect(card.name, 'Zero');
      expect(card.description, 'clone');
      expect(card.firstMes, '……');
      expect(card.exampleDialogs, 'hi');
      expect(card.systemPrompt, 'stay calm');
    });

    test('decodes a character array pack', () {
      final cards = [
        CharacterCard(name: 'A'),
        CharacterCard(name: 'B', personality: '急'),
      ];
      final json = codec.encodeCharacters(cards);
      final imported = codec.decodeCharacters(json);
      expect(imported.map((c) => c.name), ['A', 'B']);
      expect(imported[1].personality, '急');
    });
  });

  group('world info codec', () {
    test('round-trips entries', () {
      final entry = WorldInfoEntry(
        title: '青锋剑法',
        keys: const ['剑', '青锋'],
        content: '北境禁术',
        alwaysOn: false,
        enabled: true,
        priority: 3,
      );
      final json = codec.encodeWorldInfoEntry(entry);
      final imported = codec.decodeWorldInfoEntries(json).single;
      expect(imported.id, isNot(entry.id));
      expect(imported.title, entry.title);
      expect(imported.keys, entry.keys);
      expect(imported.content, entry.content);
      expect(imported.priority, 3);
    });

    test('accepts key alias and constant flag', () {
      const raw = '''
{
  "entries": [
    {
      "comment": "律法",
      "key": "王城, 律法",
      "content": "夜不闭户是假的",
      "constant": true,
      "order": 10
    }
  ]
}
''';
      final entry = codec.decodeWorldInfoEntries(raw).single;
      expect(entry.title, '律法');
      expect(entry.keys, ['王城', '律法']);
      expect(entry.alwaysOn, isTrue);
      expect(entry.priority, 10);
    });
  });
}
