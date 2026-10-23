import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/subagent_role.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/work_agent_runtime.dart';
import 'package:expert_chat/features/workbench/agents/agent_cluster_card.dart';

class _NoNetwork implements LlmProvider {
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) => const Stream.empty();
}

void main() {
  testWidgets(
    'cluster cards fit a narrow pane with long task and model names',
    (tester) async {
      tester.view.physicalSize = const Size(330, 660);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      if (const bool.fromEnvironment('RENDER_AGENT_CLUSTER')) {
        final font = FontLoader('NotoSansSC')
          ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await font.load();
        await icons.load();
      }
      final env = WorkAgentEnvironment(
        provider: _NoNetwork(),
        config: const LlmConfig(baseUrl: '', apiKey: '', model: 'model'),
        tools: const [],
        executeTool: (_, _, _, _) async => '',
        resolveModel: (_, c) async => c,
      );
      final roles = SubagentRole.defaults();
      final records = [
        for (var i = 0; i < 3; i++)
          WorkAgentRecord(
              id: '$i',
              conversationId: 'c',
              taskId: 't',
              task: [
                '检查调度与后台任务的边界，整理有证据的代码审查意见。',
                '调研数据库并发处理方案，汇总适用条件。',
                '实现任务列表的交互和布局调整。',
              ][i],
              depth: i == 2 ? 2 : 1,
              limits: const WorkAgentLimits(),
              environment: env,
            )
            ..role = roles[[2, 3, 1][i]]
            ..model = 'deepseek-v4.1-flash'
            ..status = [
              WorkAgentStatus.running,
              WorkAgentStatus.waiting,
              WorkAgentStatus.completed,
            ][i]
            ..rounds = [4, 1, 3][i],
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('cluster-render'),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(Icons.hub_outlined, size: 20),
                          SizedBox(width: 8),
                          Text('代理集群 · 3 个任务'),
                        ],
                      ),
                    ),
                    for (final r in records)
                      AgentClusterCard(
                        agent: r,
                        selected: r.id == '0',
                        onTap: () {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
      expect(find.text('代码审查'), findsOneWidget);
      if (const bool.fromEnvironment('RENDER_AGENT_CLUSTER')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('cluster-render')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final path = File('output/agent-cluster-preview.png');
          await path.parent.create(recursive: true);
          await path.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
