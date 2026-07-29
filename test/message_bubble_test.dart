import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('user message copy action copies the complete message text', (
    tester,
  ) async {
    String? copiedText;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments as Map<Object?, Object?>;
        copiedText = arguments['text'] as String?;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    const content = '这是我发送的完整内容。\n第二行也应被复制。';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(role: MessageRole.user, content: content),
            isStreaming: false,
            onEdit: (_) {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('复制'), findsOneWidget);
    await tester.tap(find.byTooltip('复制'));
    await tester.pump();

    expect(copiedText, content);
    expect(find.text('已复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('message exposes an explicit remember action', (tester) async {
    var remembered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '这是一条值得保存的结论。',
            ),
            isStreaming: false,
            onRemember: () async => remembered = true,
          ),
        ),
      ),
    );

    expect(find.byTooltip('记住这条'), findsOneWidget);
    await tester.tap(find.byTooltip('记住这条'));
    await tester.pump();
    expect(remembered, isTrue);
  });
}
