import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/tool_loop_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('chat mode uses search rounds plus one wrap-up without tools', () {
    const maxRounds = 4;
    expect(
      ToolLoopPolicy.maxRounds(workMode: false, searchMaxRounds: 3),
      maxRounds,
    );
    expect(
      ToolLoopPolicy.allowToolsThisRound(
        workMode: false,
        round: 0,
        maxRounds: maxRounds,
        enableTools: true,
        hasToolSpecs: true,
      ),
      isTrue,
    );
    expect(
      ToolLoopPolicy.allowToolsThisRound(
        workMode: false,
        round: maxRounds - 1,
        maxRounds: maxRounds,
        enableTools: true,
        hasToolSpecs: true,
      ),
      isFalse,
    );
    expect(ToolLoopPolicy.maxCallsPerRound(workMode: false), 3);
  });

  test('work mode keeps tools until the safety cap wrap-up', () {
    final maxRounds = ToolLoopPolicy.maxRounds(
      workMode: true,
      searchMaxRounds: 3,
    );
    expect(maxRounds, ToolLoopPolicy.workSafetyRounds);
    expect(
      ToolLoopPolicy.allowToolsThisRound(
        workMode: true,
        round: 10,
        maxRounds: maxRounds,
        enableTools: true,
        hasToolSpecs: true,
      ),
      isTrue,
    );
    expect(
      ToolLoopPolicy.allowToolsThisRound(
        workMode: true,
        round: maxRounds - 1,
        maxRounds: maxRounds,
        enableTools: true,
        hasToolSpecs: true,
      ),
      isFalse,
    );
    expect(ToolLoopPolicy.maxCallsPerRound(workMode: true), 8);
  });

  test('conversation workMode round-trips through JSON', () {
    final conversation = Conversation(id: 'w1', workMode: true);
    expect(Conversation.fromJson(conversation.toJson()).workMode, isTrue);
    expect(Conversation.fromJson(const {'id': 'legacy'}).workMode, isFalse);
  });
}
