import 'package:expert_chat/data/chat_skill.dart';
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

  testWidgets('assistant reasoning remains available as a collapsible panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '最终回答',
              reasoning: '这里是可展开的思考过程',
              thinkingMillis: 4200,
            ),
            isStreaming: false,
          ),
        ),
      ),
    );

    expect(find.text('已思考 (用时 4 秒)'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showFirst,
    );

    await tester.tap(find.text('已思考 (用时 4 秒)'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
          .crossFadeState,
      CrossFadeState.showSecond,
    );
    expect(find.text('这里是可展开的思考过程'), findsOneWidget);
    expect(find.text('最终回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool calls without reasoning still open the thinking chain', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '已经改好文档。',
              searchActivities: [
                SearchActivity(
                  kind: SearchActivityKind.mcp,
                  query: 'list_files',
                  status: SearchActivityStatus.done,
                  resultCount: 1,
                ),
                SearchActivity(
                  kind: SearchActivityKind.document,
                  query: 'edit_document',
                  status: SearchActivityStatus.done,
                  resultCount: 1,
                  items: const [SearchActivityItem(title: '报告.docx')],
                ),
              ],
            ),
            isStreaming: false,
          ),
        ),
      ),
    );

    expect(find.text('已思考'), findsOneWidget);
    expect(find.text('已调用 list_files'), findsOneWidget);
    expect(find.text('已编辑文档'), findsOneWidget);
    expect(find.text('报告.docx'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thinking process hides the leftover sources bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '华科图书馆是红砖建筑。',
              citations: const [
                Citation(
                  index: 1,
                  title: '华中科技大学',
                  url: 'https://www.hust.edu.cn',
                ),
              ],
              searchActivities: [
                SearchActivity(
                  kind: SearchActivityKind.search,
                  query: '华科图书馆',
                  status: SearchActivityStatus.done,
                  resultCount: 1,
                  items: const [
                    SearchActivityItem(
                      title: '华中科技大学',
                      url: 'https://www.hust.edu.cn',
                    ),
                  ],
                ),
              ],
            ),
            isStreaming: false,
          ),
        ),
      ),
    );

    expect(find.textContaining('来源'), findsNothing);
    expect(find.text('搜索到 1 个网页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy citations still show when there is no thinking process', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '华科图书馆是红砖建筑。',
              citations: const [
                Citation(
                  index: 1,
                  title: '华中科技大学',
                  url: 'https://www.hust.edu.cn',
                ),
              ],
            ),
            isStreaming: false,
          ),
        ),
      ),
    );

    expect(find.text('来源 · 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant bubble shows turn skill chip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              role: MessageRole.assistant,
              content: '按你的要求改写好了。',
              turnSkill: const TurnSkillMark(
                id: 'writing',
                name: '写作',
                source: ChatSkillSource.model,
              ),
            ),
            isStreaming: false,
          ),
        ),
      ),
    );

    expect(find.textContaining('本轮：写作'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
  });
}
