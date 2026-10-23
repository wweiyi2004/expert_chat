import 'dart:convert';

import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/features/chat/widgets/command_activity_dialog.dart';
import 'package:expert_chat/features/chat/widgets/work_round_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SearchActivity _activity({String? args, String? output}) => SearchActivity(
  kind: SearchActivityKind.mcp,
  query: '运行命令',
  status: SearchActivityStatus.done,
  toolName: 'work_run_command',
  toolArguments: args,
  resultText: output,
);

void main() {
  test(
    'command JSON is decoded once and runner streams preserve whitespace',
    () {
      const command = 'cd "E:\\work\\project"\nWrite-Output "hello"';
      const stdout = ' lib/main.dart   | 12 ++++++\n path with space |  2 --\n';
      final details = CommandActivityDetails.fromActivity(
        _activity(
          args: jsonEncode({'command': command, 'timeout_seconds': 60}),
          output: '退出码：0\n$stdout\n标准错误：\nwarning: example\n',
        ),
      );
      expect(details.command, command);
      expect(details.exitCode, '0');
      expect(details.stdout, stdout);
      expect(details.stderr, 'warning: example\n');
      expect(details.otherArguments, {'timeout_seconds': 60});
      expect(details.rawArguments, isNull);
    },
  );

  test(
    'unknown and interrupted results remain raw without invented streams',
    () {
      const output = '命令超时，已请求终止本机进程。\n partial\n output';
      final details = CommandActivityDetails.fromActivity(
        _activity(args: '{"command":', output: output),
      );
      expect(details.command, isNull);
      expect(details.rawArguments, '{"command":');
      expect(details.exitCode, isNull);
      expect(details.stdout, isNull);
      expect(details.stderr, isNull);
      expect(details.output, output);
    },
  );

  testWidgets('command detail is readable and scrollable in a narrow pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const command =
        'git -C "E:\\work\\a project" diff --stat\nWrite-Output "done"';
    final output =
        '${' lib/very_long_directory_name/with_another_directory/main.dart  | 42 ++++++++++++++++++++\n' * 10} 10 files changed\n';
    final activity = _activity(
      args: jsonEncode({'command': command, 'timeout_seconds': 60}),
      output: '退出码：0\n$output',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkRoundActivity(
            reasoning: '',
            activities: [activity],
            running: false,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('work-round-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已运行命令'));
    await tester.pumpAndSettle();
    final commandWidget = tester.widget<SelectableText>(
      find.byKey(const ValueKey('command-detail-command')),
    );
    expect(commandWidget.data, command);
    expect(commandWidget.style?.fontFamily, 'Consolas');
    final stdoutWidget = tester.widget<SelectableText>(
      find.byKey(const ValueKey('command-detail-stdout')),
    );
    expect(stdoutWidget.data, output);
    expect(stdoutWidget.style?.fontFamily, 'Consolas');
    expect(find.text('退出码 0'), findsOneWidget);
    expect(find.byTooltip('复制命令'), findsOneWidget);
    expect(find.text('复制输出'), findsOneWidget);
    expect(find.byTooltip('关闭命令详情').hitTestable(), findsOneWidget);
    expect(find.text('timeout_seconds'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('command-wrap-toggle')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('command-detail-command')),
          )
          .data,
      command,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭命令详情'));
    await tester.pumpAndSettle();
    expect(find.byType(CommandActivityDialog), findsNothing);
  });
}
