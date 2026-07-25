import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/story/story_prompt_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseOutlineBeats', () {
    test('splits headers and bullets', () {
      const raw = '''
## 开端
- 相遇
- 冲突
## 高潮
决战
''';
      final beats = parseOutlineBeats(raw);
      expect(beats, ['开端', '相遇', '冲突', '高潮', '决战']);
    });
  });

  group('StoryPromptAssembler', () {
    final assembler = StoryPromptAssembler();

    test('orders global, character, world info, outline, author note', () {
      final card = CharacterCard(
        name: '林晚',
        description: '剑客',
        personality: '冷淡',
        scenario: '客栈',
      );
      final wi = WorldInfoEntry(
        id: 'wi1',
        title: '剑法',
        keys: const ['剑'],
        content: '青锋剑法',
        alwaysOn: false,
        enabled: true,
        priority: 1,
      );
      final convo = Conversation(
        mode: ConversationMode.story,
        characterId: card.id,
        worldInfoIds: [wi.id],
        outline: '## 第一拍\n- 入城',
        authorNote: '文风偏冷',
        plotCursor: 0,
      );
      final path = [
        ChatMessage(role: MessageRole.user, content: '拔剑吧'),
      ];

      final prefix = assembler.buildSystemPrefix(
        globalSystemPrompt: '全局人设',
        character: card,
        worldInfoPool: [wi],
        conversation: convo,
        historyPath: path,
      );

      final joined = prefix.map((m) => m.content).join('\n---\n');
      expect(prefix, isNotEmpty);
      expect(prefix.every((m) => m.role == MessageRole.system), isTrue);
      expect(joined, contains('全局人设'));
      expect(joined, contains('林晚'));
      expect(joined, contains('青锋剑法')); // keyword 剑 hit
      expect(joined, contains('导演指令'));
      expect(joined, contains('文风偏冷'));
      expect(joined, contains('当前节拍'));
    });

    test('always-on world info injects without keyword', () {
      final wi = WorldInfoEntry(
        id: 'w',
        title: '魔法',
        keys: const ['不会出现'],
        content: '魔力潮汐',
        alwaysOn: true,
        enabled: true,
      );
      final convo = Conversation(
        mode: ConversationMode.story,
        worldInfoIds: [wi.id],
      );
      final prefix = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        character: null,
        worldInfoPool: [wi],
        conversation: convo,
        historyPath: const [],
      );
      expect(prefix.map((m) => m.content).join(), contains('魔力潮汐'));
    });

    test('skips world info not selected by session', () {
      final wi = WorldInfoEntry(
        id: 'w',
        title: '秘密',
        content: '不该出现',
        alwaysOn: true,
        enabled: true,
      );
      final convo = Conversation(
        mode: ConversationMode.story,
        worldInfoIds: const [], // not selected
      );
      final prefix = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        character: null,
        worldInfoPool: [wi],
        conversation: convo,
        historyPath: const [],
      );
      expect(prefix.map((m) => m.content).join(), isNot(contains('不该出现')));
    });

    test('advancePlot adds instruction block', () {
      final convo = Conversation(
        mode: ConversationMode.story,
        outline: '- A\n- B',
        plotCursor: 0,
      );
      final prefix = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        character: null,
        worldInfoPool: const [],
        conversation: convo,
        historyPath: const [],
        advancePlot: true,
      );
      expect(prefix.map((m) => m.content).join(), contains('推进情节'));
    });
  });
}
