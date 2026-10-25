import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/task_supervisor.dart';
import 'package:expert_chat/domain/tools/math/math_toolkit.dart';
import 'capability_evolution_test.dart' show FakeLlm;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = LlmConfig(
    baseUrl: 'http://localhost',
    apiKey: 'unused',
    model: 'model',
  );
  const snapshot = SupervisorSnapshot(
    taskId: 'task',
    version: 'v1',
    round: 0,
    trigger: 'delivery',
    goal: 'finish',
    allowedModels: ['model'],
  );
  test(
    'supervisor rejects truncated JSON and repeated cumulative usage counted once',
    () async {
      final supervisor = TaskSupervisor();
      final token = CancelToken();
      final provider = FakeLlm((selected) async* {
        expect(selected.allowReasoningRetry, false);
        yield const ChatChunk(
          contentDelta:
              '{"advice":"","evidence":"","requested_tools":[],"suggested_model":""}',
          usage: LlmUsage(inputTokens: 50, outputTokens: 10),
        );
        yield const ChatChunk(
          finishReason: 'length',
          usage: LlmUsage(inputTokens: 50, outputTokens: 10),
        );
      });
      expect(
        await supervisor.review(
          settings: const SupervisorConfig(enabled: true, model: 'model'),
          snapshot: snapshot,
          provider: provider,
          config: config,
          cancelToken: token,
        ),
        isNull,
      );
      expect(supervisor.metrics.interventions, 0);
      expect(supervisor.metrics.reportedInputTokens, 50);
      expect(supervisor.metrics.reportedOutputTokens, 10);
      expect(supervisor.metrics.usageReports, 1);
      token.cancel();
    },
  );
  test(
    'enabled supervisor no-op measures request without false intervention',
    () async {
      final supervisor = TaskSupervisor();
      final token = CancelToken();
      final provider = FakeLlm((_) async* {
        yield const ChatChunk(
          contentDelta:
              '{"advice":"","evidence":"","requested_tools":[],"suggested_model":""}',
          finishReason: 'stop',
        );
      });
      final result = await supervisor.review(
        settings: const SupervisorConfig(enabled: true, model: 'model'),
        snapshot: snapshot,
        provider: provider,
        config: config,
        cancelToken: token,
      );
      expect(result?.isIntervention, false);
      expect(supervisor.metrics.noAdvice, 1);
      expect(supervisor.metrics.usageReports, 0);
      expect(supervisor.metrics.interventions, 0);
      expect(supervisor.metrics.toJson()['cost'], contains('unknown'));
      token.cancel();
    },
  );
  test(
    'in-flight cancellation terminates isolated math process promptly',
    () async {
      rootBundle.evict('assets/math/toolkit.py');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler('flutter/assets', (message) async {
        final asset = utf8.decode(
          message!.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        );
        if (asset != 'assets/math/toolkit.py') return null;
        final bytes = Uint8List.fromList(
          utf8.encode('import time\ntime.sleep(20)\nprint("{}")'),
        );
        return ByteData.view(bytes.buffer);
      });
      addTearDown(() {
        messenger.setMockMessageHandler('flutter/assets', null);
        rootBundle.evict('assets/math/toolkit.py');
      });
      final token = CancelToken();
      final timer = Stopwatch()..start();
      final result = MathToolkit().execute({
        'operation': 'exact',
        'expression': '1',
      }, cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      token.cancel('stop');
      await expectLater(result, throwsA(isA<DioException>()));
      expect(timer.elapsed, lessThan(const Duration(seconds: 5)));
    },
  );
}
