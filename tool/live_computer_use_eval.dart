import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/data/gateway_config.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/chat/generation_execution.dart';
import 'package:expert_chat/domain/chat/tool_call_runner.dart';
import 'package:expert_chat/domain/document/document_service_client.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/openai_compatible_provider.dart';
import 'package:expert_chat/domain/mcp/computer_use_policy.dart';
import 'package:expert_chat/domain/mcp/mcp_client.dart';
import 'package:expert_chat/domain/mcp/mcp_host_tools.dart';

/// Real-model, real-driver evaluation, restricted to one disposable document.
/// Screenshots and unrelated Notepad tab labels are withheld from this test.
class ScopedDesktopClient extends McpClient {
  ScopedDesktopClient(this.filename);
  final String filename;
  Map<String, dynamic>? target;
  final Set<String> _handles = {};
  static const tools = {
    'get_window_state',
    'click',
    'set_value',
    'hotkey',
    'verify_state',
  };

  Future<Map<String, dynamic>> locate(GatewayConnection connection) async {
    final response = await super.callTool(
      connection: connection,
      name: 'list_windows',
      arguments: {},
    );
    final candidates = <String, Map<String, dynamic>>{};
    void walk(Object? value) {
      if (value is Map) {
        if (value['title'] is String &&
            (value['title'] as String).contains(filename) &&
            value['window_id'] is int) {
          candidates['${value['pid']}:${value['window_id']}'] =
              Map<String, dynamic>.from(value);
        }
        for (final nested in value.values) {
          walk(nested);
        }
      } else if (value is List) {
        for (final nested in value) {
          walk(nested);
        }
      }
    }

    walk(response.structuredContent);
    if (candidates.length != 1) {
      throw StateError('Test document is not the sole matching active window');
    }
    return candidates.values.single;
  }

  @override
  Future<McpToolResult> callTool({
    required GatewayConnection connection,
    required String name,
    required Map<String, dynamic> arguments,
    CancelToken? cancelToken,
  }) async {
    if (!tools.contains(name)) {
      throw const McpClientException('测试仅允许专用窗口的编辑与保存工具');
    }
    final current = await locate(connection);
    if (current['pid'] != target!['pid'] ||
        current['window_id'] != target!['window_id'] ||
        arguments['pid'] != current['pid'] ||
        arguments['window_id'] != current['window_id']) {
      throw const McpClientException('目标已变化或超出测试窗口，停止操作');
    }
    if ({'click', 'set_value'}.contains(name) &&
        !_handles.contains(arguments['element_token'])) {
      throw const McpClientException('测试要求使用当前观察中允许的 element_token');
    }
    if (name == 'hotkey' && jsonEncode(arguments['keys']) != '["ctrl","s"]') {
      throw const McpClientException('测试只允许 Ctrl+S 保存快捷键');
    }
    final response = await super.callTool(
      connection: connection,
      name: name,
      arguments: {
        ...arguments,
        if (name == 'get_window_state') 'include_screenshot': false,
      },
      cancelToken: cancelToken,
    );
    final structured = response.structuredContent;
    if (structured['elements'] is! List) {
      return McpToolResult(
        content: [
          {'type': 'text', 'text': response.text},
        ],
        structuredContent: {},
        isError: response.isError,
      );
    }
    final elements = (structured['elements'] as List)
        .whereType<Map>()
        .where((element) {
          if (element['role'] == 'Document') return true;
          if (element['role'] != 'MenuItem') return false;
          return RegExp(
            r'^(文件|File|保存|Save)(\s|\(|$)',
          ).hasMatch('${element['label']}');
        })
        .map((element) => Map<String, dynamic>.from(element))
        .toList();
    _handles
      ..clear()
      ..addAll(elements.map((e) => e['element_token']).whereType<String>());
    final text = jsonEncode({
      'window_title': filename,
      'snapshot_id': structured['snapshot_id'],
      'pid': structured['pid'],
      'window_id': structured['window_id'],
      'elements': elements,
      'note':
          'Only the test document editor and File/Save menu controls are included. Use the latest element_token.',
    });
    return McpToolResult(
      content: [
        {'type': 'text', 'text': text},
      ],
      structuredContent: {
        'snapshot_id': structured['snapshot_id'],
        'pid': structured['pid'],
        'window_id': structured['window_id'],
        'elements': elements,
      },
      isError: response.isError,
    );
  }
}

Future<void> main(List<String> args) async {
  final key = Platform.environment['EXPERT_CHAT_TEST_API_KEY'] ?? '';
  final baseUrl = Platform.environment['EXPERT_CHAT_TEST_BASE_URL'] ?? '';
  final model = Platform.environment['EXPERT_CHAT_TEST_MODEL'] ?? '';
  if (key.isEmpty || baseUrl.isEmpty || model.isEmpty || args.isEmpty) {
    stderr.writeln(
      'Configured model credentials and a Cua Driver path are required.',
    );
    exitCode = 2;
    return;
  }
  final runId = DateTime.now().millisecondsSinceEpoch.toString();
  final directory = Directory('build/computer-use-live/$runId').absolute;
  await directory.create(recursive: true);
  final filename = 'expert-chat-live-$runId.txt';
  final file = File('${directory.path}/$filename');
  await file.writeAsString('Expert Chat isolated live test\n');
  final expected = 'Expert Chat 真实模型测试成功 $runId';
  final client = ScopedDesktopClient(filename);
  final documentClient = DocumentServiceClient(mcp: client);
  final connection = GatewayConnection(
    config: const GatewayConfig(enabled: true, requestTimeoutSeconds: 30),
    apiToken: '',
    localProcess: McpProcessConfig(
      command: args.first,
      arguments: const ['mcp', '--direct'],
    ),
    computerUse: true,
  );
  final modelDio = Dio(
    BaseOptions(connectTimeout: const Duration(seconds: 30)),
  );
  final llm = OpenAiCompatibleProvider(dio: modelDio);
  final config = LlmConfig(baseUrl: baseUrl, apiKey: key, model: model);
  final execution = GenerationExecution()..tryStart();
  final cancel = CancelToken();
  execution.attachRequest(cancel);
  execution.beginBudget(
    const TaskBudgetPrefs(workSeconds: 300, maxToolCalls: 24, maxSearches: 0),
    beforeCancel: () {},
  );
  final events = <Map<String, dynamic>>[];
  var finalText = '';
  var rounds = 0;
  var totalInput = 0, totalOutput = 0;
  final timer = Stopwatch()..start();
  try {
    final server = await client.discover(connection: connection);
    final tools = [
      for (final tool in server.tools)
        if (ScopedDesktopClient.tools.contains(tool.name))
          McpHostTools.toSpec(
            ComputerUsePolicy.modelTool(
              DiscoveredMcpTool(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema,
              ),
              false,
            ),
          ),
    ];
    await Process.start('notepad.exe', [
      file.path,
    ], mode: ProcessStartMode.detached);
    await Future<void>.delayed(const Duration(seconds: 2));
    client.target = await client.locate(connection);
    final target = client.target!;
    final history = <LlmRequestMessage>[
      const LlmRequestMessage(
        role: MessageRole.system,
        content: ComputerUsePolicy.guidance,
      ),
      LlmRequestMessage(
        role: MessageRole.user,
        content:
            '这是一次真实操作测试。专用记事本文档已打开，窗口 pid=${target['pid']}，window_id=${target['window_id']}。'
            '请自主观察窗口，把当前文档内容完整替换为下面这一行文字，然后通过记事本保存到当前文件，核验后再报告结果。'
            '不要操作其他文档、其他窗口，也不要使用终端、脚本或其他文件写入方式。保持后台模式。'
            '目标文件：$filename。要求文字：$expected。',
      ),
    ];
    while (rounds < 12 && !cancel.isCancelled) {
      rounds++;
      final text = StringBuffer();
      final reasoning = StringBuffer();
      final calls = <int, ToolCallDraft>{};
      await for (final chunk in llm.streamChat(
        config: config,
        messages: history,
        tools: tools,
        thinking: false,
        cancelToken: cancel,
      )) {
        if (chunk.contentDelta != null) text.write(chunk.contentDelta);
        if (chunk.reasoningDelta != null) reasoning.write(chunk.reasoningDelta);
        for (final call in chunk.toolCalls ?? <ToolCall>[]) {
          (calls[call.index] ??= ToolCallDraft(call.index)).merge(call);
        }
        if (chunk.usage != null) {
          totalInput += chunk.usage!.inputTokens;
          totalOutput += chunk.usage!.outputTokens;
        }
      }
      final toolCalls = ToolCallDraft.finalize(calls);
      finalText = text.toString();
      events.add({
        'round': rounds,
        'assistant': finalText,
        'tools': toolCalls.map((c) => c.name).toList(),
      });
      stdout.writeln(
        'Round $rounds: ${toolCalls.map((c) => c.name).join(', ')}',
      );
      if (toolCalls.isEmpty) break;
      history.add(
        LlmRequestMessage(
          role: MessageRole.assistant,
          content: finalText,
          reasoningContent: reasoning.toString(),
          toolCalls: toolCalls,
        ),
      );
      final results = await ToolCallRunner(execution).run(
        calls: toolCalls,
        maxCalls: 3,
        cancelToken: cancel,
        execute: (call) async {
          final watch = Stopwatch()..start();
          try {
            final arguments = Map<String, dynamic>.from(
              jsonDecode(call.argumentsJson) as Map,
            );
            final result = await documentClient.callDiscoveredTool(
              connection: connection,
              name: call.name!,
              arguments: arguments,
              cancelToken: cancel,
            );
            events.add({
              'tool': call.name,
              'arguments': arguments,
              'ms': watch.elapsedMilliseconds,
              'result': result.text,
            });
            return result.text;
          } catch (error) {
            final message = error.toString();
            events.add({
              'tool': call.name,
              'ms': watch.elapsedMilliseconds,
              'error': message,
            });
            return '工具执行失败：$message。先重新观察再决定下一步，不要直接重放动作。';
          }
        },
      );
      history.addAll(results);
      await File(
        '${directory.path}/trace.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(events));
    }
  } catch (error) {
    events.add({'error': error.runtimeType.toString()});
    stderr.writeln('Test stopped: ${error.runtimeType}');
  } finally {
    execution.dispose();
    await client.close();
    modelDio.close(force: true);
    final actual = await file.readAsString();
    final report = {
      'model': model,
      'rounds': rounds,
      'elapsed_ms': timer.elapsedMilliseconds,
      'input_tokens': totalInput,
      'output_tokens': totalOutput,
      'file_verified': actual.trim() == expected,
      'final_answer': finalText,
      'expected': expected,
      'file': file.path,
      'scope':
          'real model and production provider/MCP/policy/tool runner; preopened test window; UIA text only; no ChatPage UI',
      'trace': events,
    };
    await File(
      '${directory.path}/report.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(
      jsonEncode({
        'file_verified': report['file_verified'],
        'rounds': rounds,
        'elapsed_ms': timer.elapsedMilliseconds,
        'final_answer': finalText,
        'report': '${directory.path}/report.json',
      }),
    );
    if (report['file_verified'] != true) exitCode = 1;
  }
}
