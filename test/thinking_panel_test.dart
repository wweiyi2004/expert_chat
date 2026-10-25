import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/thinking_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'work status stays in footer and actual tool params/results are separate',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThinkingPanel(
              reasoning: '',
              isStreaming: true,
              workMode: true,
              onStop: () {},
              activities: [
                SearchActivity(
                  kind: SearchActivityKind.mcp,
                  query: '目录',
                  status: SearchActivityStatus.done,
                  toolName: 'coding_list_directory',
                  toolArguments: '{"path":"src"}',
                  resultText:
                      '{"entries":[{"name":"main.dart","kind":"file","access":"read"}]}',
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('正在处理 · 1 个步骤'), findsOneWidget);
      final status = tester.getRect(find.text('正在处理 · 1 个步骤'));
      final collapse = tester.getRect(
        find.byKey(const ValueKey('work-round-collapse-bottom')),
      );
      final step = tester.getRect(find.text('已查看文件目录 · src'));
      expect(status.top, greaterThan(step.bottom));
      expect((status.center.dy - collapse.center.dy).abs(), lessThan(1));
      await tester.tap(find.text('已查看文件目录 · src'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('参数'), findsOneWidget);
      expect(find.text('结果'), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('read'), findsOneWidget);
      expect(find.text('复制原始数据'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'completed work folds by round and reveals summaries before raw details',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ThinkingPanel(
                reasoning: '',
                isStreaming: false,
                workMode: true,
                activities: [
                  SearchActivity(
                    kind: SearchActivityKind.mcp,
                    query: '工作区',
                    status: SearchActivityStatus.done,
                    toolName: 'coding_read_file',
                    toolArguments: '{"path":"src/main.dart"}',
                    resultText: '读取到的文件正文',
                    roundElapsedMillis: 2209000,
                  ),
                  SearchActivity(
                    kind: SearchActivityKind.mcp,
                    query: '写入文件',
                    status: SearchActivityStatus.failed,
                    error: '目录为只读',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('用时 36m 49s · 1 步未完成'), findsOneWidget);
      expect(find.text('读取到的文件正文'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('work-round-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('已读取文件 · src/main.dart'), findsOneWidget);
      expect(find.text('读取到的文件正文'), findsNothing);
      await tester.tap(find.text('已读取文件 · src/main.dart'));
      await tester.pumpAndSettle();
      expect(find.textContaining('读取到的文件正文'), findsOneWidget);
      expect(find.byKey(const ValueKey('thinking-panel-toggle')), findsNothing);
      expect(find.text('查看结果'), findsNothing);
    },
  );
  testWidgets(
    'folded live reasoning follows the newest lines locally and hides when finished',
    (tester) async {
      var reasoning = List.generate(12, (index) => '思考步骤 $index').join('\n');
      Widget panel(bool streaming) => MaterialApp(
        home: Scaffold(
          body: ThinkingPanel(reasoning: reasoning, isStreaming: streaming),
        ),
      );
      await tester.pumpWidget(panel(true));
      await tester.pump(const Duration(milliseconds: 200));
      final viewport = find.byKey(const ValueKey('thinking-collapsed-scroll'));
      expect(viewport, findsOneWidget);
      final scroll = tester.widget<SingleChildScrollView>(viewport).controller!;
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      final previousOffset = scroll.offset;
      reasoning += '\n正在核对最后一项\n得到新的结果';
      await tester.pumpWidget(panel(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(scroll.offset, greaterThan(previousOffset));
      expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
      await tester.tap(find.byKey(const ValueKey('thinking-panel-toggle')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        reasoning,
      );
      await tester.tap(find.byKey(const ValueKey('thinking-panel-toggle')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(panel(false));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('thinking-collapsed-preview')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

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
      await tester.tap(find.byKey(const ValueKey('thinking-panel-toggle')));
      await tester.pump(const Duration(milliseconds: 200));
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
