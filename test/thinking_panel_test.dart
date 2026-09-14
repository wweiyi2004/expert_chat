import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/thinking_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('steps expose recovery, duration and saved results', (
    tester,
  ) async {
    var retries = 0;
    var answers = 0;
    final step = SearchActivity(
      kind: SearchActivityKind.search,
      query: '资料',
      status: SearchActivityStatus.failed,
      error: '连接失败',
      toolName: 'web_search',
      toolArguments: '{"query":"资料"}',
      resultText: '已保存的正文',
      startedAt: DateTime(2026),
      finishedAt: DateTime(2026).add(const Duration(seconds: 2)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThinkingPanel(
            reasoning: '',
            isStreaming: false,
            activities: [step],
            onRetryStep: (_) => retries++,
            onAnswerFromResults: () => answers++,
          ),
        ),
      ),
    );
    expect(find.text('耗时 2.0 秒'), findsOneWidget);
    await tester.tap(find.text('仅重试此步骤'));
    await tester.tap(find.text('用已有资料回答'));
    expect(retries, 1);
    expect(answers, 1);
    await tester.tap(find.text('查看结果'));
    await tester.pumpAndSettle();
    expect(find.text('已保存的正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('running search and image steps never claim completion', (
    tester,
  ) async {
    for (final kind in [SearchActivityKind.search, SearchActivityKind.image]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThinkingPanel(
              reasoning: '',
              isStreaming: true,
              activities: [
                SearchActivity(
                  kind: kind,
                  query: kind == SearchActivityKind.image ? '优化提示词' : '天气资料',
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('已搜索'), findsNothing);
      expect(find.text('已生成图片'), findsNothing);
      expect(
        find.text(kind == SearchActivityKind.image ? '正在优化生图提示词…' : '正在搜索…'),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'stopped work is interrupted and completed image stages are distinct',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThinkingPanel(
              reasoning: '',
              isStreaming: false,
              activities: [
                SearchActivity(
                  kind: SearchActivityKind.image,
                  query: '优化提示词',
                  status: SearchActivityStatus.done,
                ),
                SearchActivity(kind: SearchActivityKind.image, query: '生成图片'),
              ],
            ),
          ),
        ),
      );
      expect(find.text('生图提示词已就绪'), findsOneWidget);
      expect(find.text('已中断：生成图片'), findsOneWidget);
      expect(find.text('已生成图片'), findsNothing);
    },
  );

  testWidgets(
    'long reasoning is previewed and can be expanded without losing text',
    (tester) async {
      final reasoning = '开头${'思考内容' * 300}结尾';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ThinkingPanel(reasoning: reasoning, isStreaming: true),
            ),
          ),
        ),
      );
      final preview = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(preview.data!.length, 1000);
      expect(preview.data, endsWith('结尾'));
      await tester.tap(find.text('展开完整思考（${reasoning.length} 字）'));
      await tester.pump();
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        reasoning,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
