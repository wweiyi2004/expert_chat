import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/conversation_outline.dart';
import 'package:expert_chat/features/chat/widgets/conversation_outline_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildConversationOutline', () {
    test('uses user turns and assistant headings', () {
      final user = ChatMessage(
        id: 'u1',
        role: MessageRole.user,
        content: '请写一份旅行计划\n越详细越好',
      );
      final assistant = ChatMessage(
        id: 'a1',
        role: MessageRole.assistant,
        content: '# 行程概览\n正文\n## 第一天\n细节\n### 上午\n咖啡',
      );
      final entries = buildConversationOutline([user, assistant]);
      expect(entries, hasLength(4));
      expect(entries[0].title, '请写一份旅行计划');
      expect(entries[0].depth, 0);
      expect(entries[0].role, MessageRole.user);
      expect(entries[1].title, '行程概览');
      expect(entries[1].depth, 1);
      expect(entries[2].title, '第一天');
      expect(entries[2].depth, 2);
      expect(entries[3].title, '上午');
      expect(entries[3].depth, 3);
      expect(entries.every((e) => e.messageId == 'u1' || e.messageId == 'a1'), isTrue);
    });

    test('skips headings inside fenced code', () {
      final assistant = ChatMessage(
        id: 'a1',
        role: MessageRole.assistant,
        content: '# 真标题\n```md\n# 假标题\n```\n## 还在',
      );
      final entries = buildConversationOutline([assistant]);
      expect(entries.map((e) => e.title), ['真标题', '还在']);
    });

    test('clips long titles and strips markdown', () {
      final user = ChatMessage(
        id: 'u1',
        role: MessageRole.user,
        content:
            '**请解释** [链接](https://example.com) 以及后面很长很长很长很长很长很长很长很长的说明文字',
      );
      final entries = buildConversationOutline([user]);
      expect(entries.single.title.endsWith('…'), isTrue);
      expect(entries.single.title.contains('**'), isFalse);
      expect(entries.single.title.contains('https://'), isFalse);
      expect(entries.single.title.contains('请解释'), isTrue);
      expect(entries.single.title.contains('链接'), isTrue);
    });

    test('ignores empty user messages without attachments', () {
      final entries = buildConversationOutline([
        ChatMessage(id: 'u1', role: MessageRole.user, content: '   \n'),
      ]);
      expect(entries, isEmpty);
    });
  });

  testWidgets('tapping an outline row reports the message id', (tester) async {
    String? jumped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationOutlinePanel(
            entries: [
              ConversationOutlineEntry(
                messageId: 'u1',
                title: '提问',
                depth: 0,
                role: MessageRole.user,
              ),
            ],
            onJump: (id) => jumped = id,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('outline-u1-0')));
    expect(jumped, 'u1');
  });
}
