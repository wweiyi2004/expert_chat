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
      final path = [ChatMessage(role: MessageRole.user, content: '拔剑吧')];

      final build = assembler.buildSystemPrefix(
        globalSystemPrompt: '全局人设',
        character: card,
        worldInfoPool: [wi],
        conversation: convo,
        historyPath: path,
      );

      final prefix = build.messages;
      final joined = prefix.map((m) => m.content).join('\n---\n');
      expect(prefix, isNotEmpty);
      expect(prefix.every((m) => m.role == MessageRole.system), isTrue);
      expect(joined, contains('全局人设'));
      expect(joined, contains('林晚'));
      expect(joined, contains('青锋剑法')); // keyword 剑 hit
      expect(joined, contains('导演指令'));
      expect(joined, contains('文风偏冷'));
      expect(joined, contains('当前节拍'));
      expect(build.worldInfoHits.map((h) => h.title), contains('剑法'));
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
      final build = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        character: null,
        worldInfoPool: [wi],
        conversation: convo,
        historyPath: const [],
      );
      expect(build.messages.map((m) => m.content).join(), contains('魔力潮汐'));
      expect(build.worldInfoHits.single.title, '魔法');
      expect(build.worldInfoHits.single.alwaysOn, isTrue);
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
      final build = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        character: null,
        worldInfoPool: [wi],
        conversation: convo,
        historyPath: const [],
      );
      expect(
        build.messages.map((m) => m.content).join(),
        isNot(contains('不该出现')),
      );
      expect(build.worldInfoHits, isEmpty);
    });

    test('advancePlot adds instruction block', () {
      final convo = Conversation(
        mode: ConversationMode.story,
        outline: '- A\n- B',
        plotCursor: 0,
      );
      final build = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        character: null,
        worldInfoPool: const [],
        conversation: convo,
        historyPath: const [],
        advancePlot: true,
      );
      expect(build.messages.map((m) => m.content).join(), contains('推进情节'));
    });

    test('director mode assigns every story role to the AI', () {
      final cast = [
        CharacterCard(
          name: '沈砚',
          description: '追查失踪案的记者',
          personality: '谨慎而执着',
          scenario: '负责推动调查线',
        ),
        CharacterCard(
          name: '零号',
          description: '身份不明的克隆人',
          personality: '克制，几乎不使用反问句',
          scenario: '掌握飞船秘密',
        ),
      ];
      final convo = Conversation(
        title: '失控航线',
        mode: ConversationMode.story,
        outline: '- 记者在休眠舱醒来\n- 零号现身',
      );

      final build = assembler.buildSystemPrefix(
        globalSystemPrompt: '',
        cast: cast,
        worldInfoPool: const [],
        conversation: convo,
        historyPath: const [],
        advancePlot: true,
        directorMode: true,
      );

      final joined = build.messages.map((m) => m.content).join('\n');
      expect(joined, contains('用户是导演'));
      expect(joined, contains('服从优先级'));
      expect(joined, contains('硬性导演说明'));
      expect(joined, contains('沈砚'));
      expect(joined, contains('零号'));
      expect(joined, contains('不得让导演成为故事角色'));
      expect(joined, contains('当前必须演绎的节拍'));
    });

    test(
      'director mode puts hard constraints before cast and forbids freestyle',
      () {
        final cast = [CharacterCard(name: '甲', description: '路人')];
        final convo = Conversation(
          mode: ConversationMode.story,
          localCast: cast,
          outline: '- 开端\n- 高潮',
          authorNote: '【硬性创作约束】\n禁止超自然；慢热',
          plotCursor: 0,
        );
        final build = assembler.buildSystemPrefix(
          globalSystemPrompt: '',
          cast: cast,
          worldInfoPool: const [],
          conversation: convo,
          historyPath: const [],
          advancePlot: true,
          directorMode: true,
        );
        final texts = build.messages.map((m) => m.content).toList();
        final joined = texts.join('\n---\n');
        expect(joined, contains('禁止超自然'));
        expect(joined, contains('不可违背'));
        expect(joined, contains('以导演说明为准'));
        // Constraint block should appear before character cards.
        final constraintIdx = texts.indexWhere((t) => t.contains('硬性导演说明'));
        final castIdx = texts.indexWhere((t) => t.contains('本故事角色卡'));
        expect(constraintIdx, greaterThanOrEqualTo(0));
        expect(castIdx, greaterThanOrEqualTo(0));
        expect(constraintIdx, lessThan(castIdx));
      },
    );

    test(
      'director mode places hard constraints before global system prompt',
      () {
        final cast = [CharacterCard(name: '甲')];
        final convo = Conversation(
          mode: ConversationMode.story,
          localCast: cast,
          outline: '- a',
          authorNote: '【硬性创作约束】\n禁止穿越',
        );
        final build = assembler.buildSystemPrefix(
          globalSystemPrompt: '你是一个轻松吐槽役',
          cast: cast,
          worldInfoPool: const [],
          conversation: convo,
          historyPath: const [],
          advancePlot: true,
          directorMode: true,
        );
        final texts = build.messages.map((m) => m.content).toList();
        final hardIdx = texts.indexWhere((t) => t.contains('硬性导演说明'));
        final globalIdx = texts.indexWhere((t) => t.contains('全局人设'));
        expect(hardIdx, greaterThanOrEqualTo(0));
        expect(globalIdx, greaterThanOrEqualTo(0));
        expect(hardIdx, lessThan(globalIdx));
      },
    );

    test(
      'oversized director note preserves constraints and original premise',
      () {
        final cast = [CharacterCard(name: '甲')];
        final convo = Conversation(
          mode: ConversationMode.story,
          localCast: cast,
          outline: '- 开场',
          authorNote:
              '【硬性创作约束】（不可违背）\n禁止超自然\n\n'
              '${'中间说明' * 1200}\n\n'
              '【故事原始情节】（核心基调与事件不可擅自改写）\n'
              '末班车必须在黎明前回到原站。',
        );

        final build = assembler.buildSystemPrefix(
          globalSystemPrompt: '',
          cast: cast,
          worldInfoPool: const [],
          conversation: convo,
          historyPath: const [],
          advancePlot: true,
          directorMode: true,
        );
        final joined = build.messages.map((m) => m.content).join('\n');

        expect(joined, contains('禁止超自然'));
        expect(joined, contains('末班车必须在黎明前回到原站'));
        expect(joined, contains('中间导演说明已因长度裁剪'));
      },
    );
  });
}
