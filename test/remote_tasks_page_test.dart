import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/features/remote/remote_tasks_page.dart';
import 'package:expert_chat/features/remote/device_agent_page.dart';
import 'package:flutter/services.dart';

class _HostAdapter implements HttpClientAdapter {
  Completer<ResponseBody>? pendingSubmit;
  Completer<ResponseBody>? slowPoll;
  bool delayNextPoll = false;
  List<Map<String, dynamic>> tasks = [];
  int stops = 0;
  List<String> allowedPolicies = ['request'];
  final List<RequestOptions> requests = [];
  ResponseBody json(Object value) => ResponseBody.fromString(
    jsonEncode(value),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'GET' &&
        options.uri.path == '/v1/tasks' &&
        delayNextPoll) {
      delayNextPoll = false;
      return (slowPoll ??= Completer<ResponseBody>()).future;
    }
    if (options.uri.path.endsWith('/stop')) {
      stops++;
      tasks = tasks
          .map((task) => {...task, 'state': 'stopped', 'version': '2'})
          .toList();
      return json(tasks.single);
    }
    if (options.method == 'POST' && options.uri.path == '/v1/tasks') {
      return (pendingSubmit ??= Completer<ResponseBody>()).future;
    }
    return json(
      options.uri.path == '/v1/tasks'
          ? {'tasks': tasks, 'allowedPolicies': allowedPolicies}
          : {'events': []},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets(
    'pending submission survives recreation with original authorized options',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final first = _HostAdapter()..allowedPolicies = ['request', 'full'];
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteTasksPage(client: Dio()..httpClientAdapter = first),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '电脑 credential 文件中的配对密钥'),
        'fixture-key',
      );
      await tester.ensureVisible(find.text('配对 / 重连'));
      await tester.tap(find.text('配对 / 重连'));
      await tester.pumpAndSettle();
      final goal = find.widgetWithText(TextField, '电脑 Agent 目标（模型配置保留在电脑）');
      await tester.ensureVisible(goal);
      await tester.enterText(goal, 'Original durable goal');
      final rounds = find.widgetWithText(TextField, '模型轮次（1–200）');
      await tester.scrollUntilVisible(
        rounds,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(rounds, '3');
      await tester.ensureVisible(find.text('提交目标'));
      await tester.tap(find.text('提交目标'));
      await tester.pumpAndSettle();
      final submitted =
          first.requests
                  .firstWhere(
                    (request) =>
                        request.method == 'POST' &&
                        request.uri.path == '/v1/tasks',
                  )
                  .data
              as Map;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      first.pendingSubmit!.complete(first.json({'id': submitted['id']}));
      await tester.pumpAndSettle();
      final second = _HostAdapter()..allowedPolicies = ['request', 'full'];
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteTasksPage(client: Dio()..httpClientAdapter = second),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(goal).controller!.text,
        'Original durable goal',
      );
      await tester.ensureVisible(find.text('配对 / 重连'));
      await tester.tap(find.text('配对 / 重连'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        rounds,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(rounds, '17');
      await tester.ensureVisible(find.text('请求批准'));
      await tester.tap(find.text('请求批准'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('完全访问').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('提交目标'));
      await tester.tap(find.text('提交目标'));
      await tester.pumpAndSettle();
      final retried =
          second.requests
                  .firstWhere(
                    (request) =>
                        request.method == 'POST' &&
                        request.uri.path == '/v1/tasks',
                  )
                  .data
              as Map;
      expect(retried['id'], submitted['id']);
      expect(retried['roundLimit'], 3);
      expect(retried['policy'], 'request');
      expect(
        second.requests.every((request) => request.followRedirects == false),
        true,
      );
      second.pendingSubmit!.complete(second.json({'id': submitted['id']}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('Stop bypasses slow periodic poll and ignores its stale result', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final adapter = _HostAdapter()
      ..tasks = [
        {
          'id': 'running',
          'command': 'Remote fixture',
          'kind': 'command',
          'state': 'running',
          'version': '1',
          'updatedAt': '2026-01-01T00:00:00Z',
        },
      ];
    final old = {...adapter.tasks.single};
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteTasksPage(client: Dio()..httpClientAdapter = adapter),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '电脑 credential 文件中的配对密钥'),
      'fixture-key',
    );
    await tester.ensureVisible(find.text('配对 / 重连'));
    await tester.tap(find.text('配对 / 重连'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('停止'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    adapter.delayNextPoll = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(adapter.slowPoll, isNotNull);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '停止'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('停止'));
    await tester.pumpAndSettle();
    expect(adapter.stops, 1);
    adapter.slowPoll!.complete(
      adapter.json({
        'tasks': [old],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'manual text preparation owns dialog controller and never reuses old target',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('expert_chat/device_agent'),
            (call) async {
              calls.add(call.method);
              return {'released': false};
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('expert_chat/device_agent'),
              null,
            ),
      );
      await tester.pumpWidget(const MaterialApp(home: DeviceAgentPage()));
      await tester.tap(find.text('准备输入文字'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Prepared text');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(find.text('文字已准备，尚未发送。请重新观察并选择最新目标字段。'), findsOneWidget);
      expect(calls, isNot(contains('text')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'narrow remote UI protects pending draft and ignores unpaired late submit',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FlutterSecureStorage.setMockInitialValues({});
      final adapter = _HostAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      await tester.pumpWidget(MaterialApp(home: RemoteTasksPage(client: dio)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '电脑 credential 文件中的配对密钥'),
        'fixture-key',
      );
      await tester.ensureVisible(find.text('配对 / 重连'));
      await tester.tap(find.text('配对 / 重连'));
      await tester.pumpAndSettle();
      expect(
        adapter.requests.where((r) => r.uri.path == '/v1/tasks').length,
        1,
      );
      final goal = find.widgetWithText(TextField, '电脑 Agent 目标（模型配置保留在电脑）');
      await tester.ensureVisible(goal);
      await tester.enterText(goal, 'Keep this draft');
      await tester.pump();
      await tester.ensureVisible(find.text('提交目标'));
      await tester.tap(find.text('提交目标'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(goal).enabled, false);
      await tester.ensureVisible(find.text('移除此配对（不停止电脑任务）'));
      await tester.tap(find.text('移除此配对（不停止电脑任务）'));
      await tester.pumpAndSettle();
      adapter.pendingSubmit!.complete(
        adapter.json({
          'id': 'late',
          'command': 'Late injected result',
          'state': 'completed',
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Late injected result'), findsNothing);
      expect(
        tester.widget<TextField>(goal).controller!.text,
        'Keep this draft',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
