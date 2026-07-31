import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/domain/export/conversation_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationExport label escaping', () {
    test('escapes markdown links in speaker labels', () {
      final md = ConversationExport.messagesToMarkdown([
        ChatMessage(role: MessageRole.user, content: '开始。'),
        ChatMessage(
          role: MessageRole.assistant,
          content: '回答。',
          speakerName: '旁白 [x](https://evil.com)',
        ),
      ]);

      // A hostile name must not become a clickable link in the export.
      expect(md, contains(r'旁白 \[x\]\(https://evil.com\)'));
      expect(md, isNot(contains('[x](https://evil.com)')));
    });

    test('escapes markdown links in story character labels', () {
      final user = ChatMessage(role: MessageRole.user, content: '开始。');
      final convo = Conversation(
        title: '故事',
        mode: ConversationMode.story,
        messages: [user],
        activeChildren: {kRootKey: user.id},
      );

      final md = ConversationExport.toMarkdown(
        convo,
        characterName: '艾拉 [x](https://evil.com)',
      );
      expect(md, contains(r'\[x\]\(https://evil.com\)'));
      expect(md, isNot(contains('[x](https://evil.com)')));
    });

    test('escapes the conversation title heading', () {
      final user = ChatMessage(role: MessageRole.user, content: 'hi');
      final convo = Conversation(
        title: 'My [x](https://evil.com) chat',
        messages: [user],
        activeChildren: {kRootKey: user.id},
      );

      final md = ConversationExport.toMarkdown(convo);
      expect(md, contains(r'# My \[x\]\(https://evil.com\) chat'));
      expect(md, isNot(contains('# My [x](https://evil.com) chat')));
    });

    test('escapes the share title heading too', () {
      final user = ChatMessage(role: MessageRole.user, content: 'hi');

      final md = ConversationExport.messagesToMarkdown(
        [user],
        title: 'Share [x](https://evil.com)',
      );
      expect(md, contains(r'# Share \[x\]\(https://evil.com\)'));
    });

    test('message body markdown is preserved verbatim', () {
      final user = ChatMessage(
        role: MessageRole.user,
        content: '看 [链接](https://ok.com) 和 **加粗**',
      );

      final md = ConversationExport.messagesToMarkdown([user]);
      expect(md, contains('[链接](https://ok.com)'));
      expect(md, contains('**加粗**'));
    });
  });
}
