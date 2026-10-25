import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/features/chat/widgets/work_approval_card.dart';
import 'package:expert_chat/state/work_approvals.dart';

void main() {
  for (final approve in [true, false]) {
    testWidgets('approval preserves exact arguments and returns $approve', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final request = PendingWorkApproval(
        id: 'request',
        conversationId: 'c',
        tool: 'workspace_shell',
        arguments: '{"command":"git status --short","unknown_option":true}',
        target: '本机测试工作区',
        reason: '检查真实状态',
      );
      final decision = container
          .read(workApprovalsProvider.notifier)
          .ask(request, CancelToken());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: WorkApprovalCard(conversationId: 'c')),
          ),
        ),
      );
      await tester.tap(find.text('查看完整参数'));
      await tester.pump();
      expect(find.text(request.arguments), findsOneWidget);
      expect(find.text('以后不再询问'), findsNothing);
      await tester.tap(find.text(approve ? '批准这一次' : '拒绝'));
      await tester.pump();
      expect(await decision, approve);
      expect(tester.takeException(), isNull);
    });
  }
}
