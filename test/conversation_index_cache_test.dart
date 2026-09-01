import 'package:expert_chat/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('copyWith with the same message ids keeps branch info and new content', () {
    final user = ChatMessage(
      id: 'u',
      role: MessageRole.user,
      content: 'hi',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final assistant = ChatMessage(
      id: 'a',
      role: MessageRole.assistant,
      content: '',
      parentId: 'u',
      createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    );
    final convo = Conversation(
      id: 'c',
      messages: [user, assistant],
      activeChildren: const {kRootKey: 'u', 'u': 'a'},
      updatedAt: DateTime.utc(2026, 1, 1),
    );

    expect(convo.activePath.map((m) => m.id), ['u', 'a']);
    expect(convo.activePath.last.content, isEmpty);
    expect(convo.branchInfo('a'), (0, 1));

    final streamed = convo.copyWith(
      messages: [user, assistant.copyWith(content: 'hello')],
      updatedAt: convo.updatedAt,
    );

    expect(streamed.activePath.last.content, 'hello');
    expect(streamed.branchInfo('a'), convo.branchInfo('a'));
    expect(streamed.branchInfo('u'), convo.branchInfo('u'));
  });

  test('copyWith with a new message id rebuilds sibling branch info', () {
    final user = ChatMessage(
      id: 'u',
      role: MessageRole.user,
      content: 'hi',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final first = ChatMessage(
      id: 'a1',
      role: MessageRole.assistant,
      content: 'one',
      parentId: 'u',
      createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    );
    final convo = Conversation(
      id: 'c',
      messages: [user, first],
      activeChildren: const {kRootKey: 'u', 'u': 'a1'},
      updatedAt: DateTime.utc(2026, 1, 1),
    );
    expect(convo.branchInfo('a1').$2, 1);

    final second = ChatMessage(
      id: 'a2',
      role: MessageRole.assistant,
      content: 'two',
      parentId: 'u',
      createdAt: DateTime.utc(2026, 1, 1, 0, 0, 2),
    );
    final branched = convo.copyWith(
      messages: [user, first, second],
      activeChildren: const {kRootKey: 'u', 'u': 'a2'},
      updatedAt: convo.updatedAt,
    );

    expect(branched.branchInfo('a1'), (0, 2));
    expect(branched.branchInfo('a2'), (1, 2));
    expect(branched.activePath.last.id, 'a2');
  });
}
