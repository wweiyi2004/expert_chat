import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/story/story_length_budget.dart';
import 'package:expert_chat/domain/story/story_prompt_assembler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('countWrittenChars sums assistant body only', () {
    final user = ChatMessage(role: MessageRole.user, content: '导演：加一场雨');
    final a1 = ChatMessage(
      role: MessageRole.assistant,
      content: '一二三四五', // 5
      parentId: user.id,
    );
    final a2 = ChatMessage(
      role: MessageRole.assistant,
      content: '六七八九十', // 5
      parentId: a1.id,
    );
    final convo = Conversation(
      mode: ConversationMode.story,
      targetTotalChars: 10000,
      messages: [user, a1, a2],
      activeChildren: {kRootKey: user.id, user.id: a1.id, a1.id: a2.id},
    );
    expect(StoryLengthBudget.countWrittenChars(convo), 10);
  });

  test('forConversation derives turn band from remaining beats', () {
    final body = '字' * 2000;
    final assistant = ChatMessage(role: MessageRole.assistant, content: body);
    final convo = Conversation(
      mode: ConversationMode.story,
      outline: '- 一\n- 二\n- 三\n- 四',
      plotCursor: 1,
      targetTotalChars: 10000,
      messages: [assistant],
      activeChildren: {kRootKey: assistant.id},
    );
    final budget = StoryLengthBudget.forConversation(convo)!;
    expect(budget.written, 2000);
    expect(budget.remaining, 8000);
    expect(budget.beatsLeft, 3); // cursor 1 → beats 2,3,4
    expect(budget.currentBeatTarget, 2500);
    // Cursor was manually put on beat 2 before beat 1 reached its 2500-char
    // threshold, so the current beat also catches up that 500-char shortfall.
    expect(budget.currentBeatRemaining, 3000);
    expect(budget.turnMin, greaterThan(0));
    expect(budget.turnMax, greaterThanOrEqualTo(budget.turnMin));
    expect(budget.turnMax, lessThanOrEqualTo(budget.remaining));
    expect(budget.sessionLabel(), contains('已写'));
    expect(budget.promptBlock(advancePlot: true), contains('篇幅与节奏参考'));
  });

  test('a length-targeted beat stays active until its cumulative quota', () {
    Conversation storyWithBody(int chars) {
      final assistant = ChatMessage(
        role: MessageRole.assistant,
        content: '字' * chars,
      );
      return Conversation(
        mode: ConversationMode.story,
        outline: '- 一\n- 二\n- 三\n- 四\n- 五\n- 六\n- 七\n- 八',
        plotCursor: 0,
        targetTotalChars: 80000,
        messages: [assistant],
        activeChildren: {kRootKey: assistant.id},
      );
    }

    final partial = StoryLengthBudget.forConversation(storyWithBody(4000))!;
    expect(partial.currentBeatTarget, 10000);
    expect(partial.currentBeatRemaining, 6000);
    expect(partial.currentBeatTargetReached, isFalse);
    final guidance = partial.promptBlock(advancePlot: true);
    expect(guidance, contains('软目标'));
    expect(guidance, contains('以完成当前场景目标和自然收束为准'));
    expect(guidance, isNot(contains('硬边界')));

    final complete = StoryLengthBudget.forConversation(storyWithBody(10000))!;
    expect(complete.currentBeatRemaining, 0);
    expect(complete.currentBeatTargetReached, isTrue);
  });

  test('assembler injects length block for director mode', () {
    final convo = Conversation(
      mode: ConversationMode.story,
      outline: '- 开端\n- 发展\n- 收束',
      authorNote: '【硬性创作约束】\n慢热',
      targetTotalChars: 50000,
      localCast: [CharacterCard(name: '甲')],
    );
    final build = const StoryPromptAssembler().buildSystemPrefix(
      globalSystemPrompt: '',
      worldInfoPool: const [],
      conversation: convo,
      historyPath: const [],
      advancePlot: true,
      directorMode: true,
      cast: [CharacterCard(name: '甲')],
    );
    final joined = build.messages.map((m) => m.content).join('\n');
    expect(joined, contains('篇幅与节奏参考'));
    expect(joined, contains('5万'));
    expect(joined, contains('冲突优先级'));
  });

  test('no length block when target is zero', () {
    final convo = Conversation(
      mode: ConversationMode.story,
      outline: '- a',
      targetTotalChars: 0,
    );
    expect(StoryLengthBudget.forConversation(convo), isNull);
    final build = const StoryPromptAssembler().buildSystemPrefix(
      globalSystemPrompt: '',
      worldInfoPool: const [],
      conversation: convo,
      historyPath: const [],
      advancePlot: true,
      directorMode: true,
    );
    final joined = build.messages.map((m) => m.content).join('\n');
    // Priority list still mentions 篇幅; the hard block only appears with a target.
    expect(joined, isNot(contains('【篇幅与节奏参考')));
  });

  test('formatChars uses 万 / 千', () {
    expect(StoryLengthBudget.formatChars(80000), '8万');
    expect(StoryLengthBudget.formatChars(1500), '1.5千');
    expect(StoryLengthBudget.formatChars(42), '42');
  });

  test('beatsLeft drops to 0 once every outline beat has been advanced', () {
    final body = '字' * 2000;
    final assistant = ChatMessage(role: MessageRole.assistant, content: body);
    final convo = Conversation(
      mode: ConversationMode.story,
      outline: '- 一\n- 二',
      plotCursor: 2, // advanced past the final beat
      targetTotalChars: 10000,
      messages: [assistant],
      activeChildren: {kRootKey: assistant.id},
    );
    final budget = StoryLengthBudget.forConversation(convo)!;
    expect(budget.beatsLeft, 0);
    final block = budget.promptBlock(advancePlot: true);
    // The outline is fully advanced; nothing may claim a leftover beat.
    expect(block, contains('已无剩余节拍'));
    expect(block, isNot(contains('剩余约 1 拍')));
    expect(block, isNot(contains('剩余约 0 拍（含当前）')));
  });

  test('near-end remaining (<200) does not throw on clamp', () {
    for (final rem in [1, 50, 199, 200, 500, 899]) {
      final written = 10000 - rem;
      final body = '字' * written;
      final assistant = ChatMessage(role: MessageRole.assistant, content: body);
      final convo = Conversation(
        mode: ConversationMode.story,
        outline: '- 尾\n- 声',
        plotCursor: 1,
        targetTotalChars: 10000,
        messages: [assistant],
        activeChildren: {kRootKey: assistant.id},
      );
      final budget = StoryLengthBudget.forConversation(convo)!;
      expect(budget.remaining, rem);
      expect(budget.turnMin, lessThanOrEqualTo(budget.turnMax));
      expect(budget.turnMax, lessThanOrEqualTo(budget.remaining));
      expect(budget.turnMin, greaterThanOrEqualTo(0));
      // sessionLabel / promptBlock must also be safe (they use turnMin/Max).
      expect(budget.sessionLabel(), isNotEmpty);
      expect(budget.promptBlock(advancePlot: true), contains('篇幅与节奏参考'));
    }
  });
}
