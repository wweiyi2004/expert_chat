import 'package:expert_chat/state/work_memory.dart';
import 'package:expert_chat/state/work_operation_journal.dart';
import 'dart:convert';

import 'package:expert_chat/features/workbench/logs/work_runtime_logs_panel.dart';
import 'package:expert_chat/state/work_runtime_logs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

WorkRuntimeLogEntry _entry(
  String id, {
  String conversation = 'work',
  bool error = false,
}) => WorkRuntimeLogEntry(
  id: id,
  conversationId: conversation,
  timestamp: DateTime(2026, 10, 23, 14, 30),
  level: error ? WorkRuntimeLogLevel.error : WorkRuntimeLogLevel.info,
  phase: error ? 'network' : 'model',
  status: error ? '请求失败' : '请求完成',
  model: 'deepseek-v4.1-flash',
  durationMs: 1240,
  detail: error ? '连接中断，请检查代理设置' : '已收到模型响应',
  httpStatus: error ? 503 : null,
  requestId: 'request-$id',
);

class _Logs extends WorkRuntimeLogs {
  @override
  List<WorkRuntimeLogEntry> build() => [];
  void replace(List<WorkRuntimeLogEntry> entries) => state = entries;
  void append(WorkRuntimeLogEntry entry) => state = [...state, entry];
}

void main() {
  testWidgets(
    'log viewer scopes session, filters errors and copies filtered snapshot',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          workRuntimeLogsProvider.overrideWith(_Logs.new),
          workMemoryProvider.overrideWithValue(
            WorkMemory(read: () => null, write: (s) async => true),
          ),
          workOperationJournalProvider.overrideWithValue(
            WorkOperationJournal(read: () => null, write: (s) async => true),
          ),
        ],
      );
      addTearDown(container.dispose);
      final logs = container.read(workRuntimeLogsProvider.notifier) as _Logs;
      logs.replace([
        _entry('one'),
        _entry('two', error: true),
        _entry('other', conversation: 'other'),
      ]);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: WorkRuntimeLogsPanel(conversationId: 'work')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('全部 2'), findsOneWidget);
      expect(find.text('错误 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('错误 1'));
      await tester.pumpAndSettle();
      expect(find.text('模型请求 · 请求完成'), findsNothing);
      expect(find.text('网络 · 请求失败'), findsOneWidget);
      await tester.tap(find.text('网络 · 请求失败'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请求：request-two'), findsOneWidget);
      await tester.tap(find.byTooltip('复制当前日志'));
      await tester.pumpAndSettle();
      expect(jsonDecode(clipboard!)['id'], 'two');
      expect(clipboard, isNot(contains('request-other')));
    },
  );

  testWidgets('incoming logs follow latest until user scrolls up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(380, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        workRuntimeLogsProvider.overrideWith(_Logs.new),
        workMemoryProvider.overrideWithValue(
          WorkMemory(read: () => null, write: (s) async => true),
        ),
        workOperationJournalProvider.overrideWithValue(
          WorkOperationJournal(read: () => null, write: (s) async => true),
        ),
      ],
    );
    addTearDown(container.dispose);
    final logs = container.read(workRuntimeLogsProvider.notifier) as _Logs;
    logs.replace([for (var i = 0; i < 30; i++) _entry('$i')]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: WorkRuntimeLogsPanel(conversationId: 'work')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('work-runtime-log-list'));
    ScrollController scroll() => tester.widget<ListView>(list).controller!;
    expect(scroll().offset, closeTo(scroll().position.maxScrollExtent, 1));
    await tester.drag(list, const Offset(0, 300));
    await tester.pumpAndSettle();
    final before = scroll().offset;
    expect(before, lessThan(scroll().position.maxScrollExtent - 30));
    logs.append(_entry('new'));
    await tester.pumpAndSettle();
    expect(scroll().offset, closeTo(before, 1));
    await tester.tap(find.byType(FilterChip));
    await tester.pumpAndSettle();
    expect(scroll().offset, closeTo(scroll().position.maxScrollExtent, 1));
    expect(tester.takeException(), isNull);
  });
}
