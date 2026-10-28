import 'package:test/test.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/conversation_tree.dart';

void main() {
  test(
    'checkpoint hides the tail without losing old branches; new input starts a branch',
    () {
      final first = ChatMessage(
        id: 'u1',
        role: MessageRole.user,
        content: 'first',
      );
      final reply = ChatMessage(
        id: 'a1',
        parentId: 'u1',
        role: MessageRole.assistant,
        content: 'reply',
      );
      final later = ChatMessage(
        id: 'u2',
        parentId: 'a1',
        role: MessageRole.user,
        content: 'later',
      );
      final c = Conversation(
        id: 'c',
        messages: [first, reply, later],
        activeChildren: {'': 'u1', 'u1': 'a1', 'a1': kCheckpointEnd},
      );
      expect(c.activePath.map((m) => m.id), ['u1', 'a1']);
      expect(c.messages, hasLength(3));
      final restored = Conversation.fromJson(c.toJson());
      expect(restored.activePath.map((m) => m.id), ['u1', 'a1']);
      final child = ChatMessage(
        id: 'u3',
        parentId: 'a1',
        role: MessageRole.user,
        content: 'new branch',
      );
      final next = c.copyWith(
        messages: [...c.messages, child],
        activeChildren: activeChildrenAfterAppending(
          c.activeChildren,
          c.activePath,
          parentId: 'a1',
          childId: 'u3',
        ),
      );
      expect(next.activePath.map((m) => m.id), ['u1', 'a1', 'u3']);
      expect(next.childrenOf('a1'), hasLength(2));
    },
  );
}
