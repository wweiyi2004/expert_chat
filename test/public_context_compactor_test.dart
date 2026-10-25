import 'dart:convert';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/context/public_context_compactor.dart';

class _Recorder implements LlmProvider {
  int calls = 0;
  String finish = 'stop';
  List<LlmRequestMessage> messages = [];
  LlmConfig? selected;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls++;
    selected = config;
    this.messages = messages;
    expect(tools, isNull);
    expect(thinking, false);
    yield ChatChunk(
      contentDelta:
          '{"summary":"Public verified work","constraints":"Keep user edits","plan":"Verify final output","open_questions":["Check current artifact"]}',
      finishReason: finish,
      usage: const LlmUsage(inputTokens: 100, outputTokens: 30),
    );
  }
}

class _IgnoringCancellation implements LlmProvider {
  bool cancellationRequested = false;
  CancelToken? token;
  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) {
    token = cancelToken;
    return StreamController<ChatChunk>(
      onCancel: () {
        cancellationRequested = true;
        return Completer<void>().future;
      },
    ).stream;
  }
}

void main() {
  const config = LlmConfig(
    baseUrl: 'https://unused.invalid',
    apiKey: 'unused',
    model: 'model',
  );
  test(
    'pressure triggers bounded checkpoints before dropping, preserving raw goal and source version',
    () async {
      final service = PublicContextCompactor(),
          provider = _Recorder(),
          token = CancelToken();
      expect(
        service.shouldCompact(
          taskId: 't',
          round: 0,
          estimatedTokens: 710,
          inputBudgetTokens: 1000,
          historyCount: 10,
        ),
        false,
      );
      Future<PublicContextCheckpoint?> compact(int round) => service.compact(
        taskId: 't',
        sourceVersion: 'memory-v1',
        round: round,
        estimatedTokens: 3000,
        inputBudgetTokens: 4096,
        historyCount: 50,
        goal: 'Exact raw user goal 保留约束',
        publicText: '\\\n"' * 20000,
        publicNotes: ['Public next action'],
        config: config.copyWith(
          modelFallbacks: [config.copyWith(model: 'other')],
        ),
        provider: provider,
        cancelToken: token,
      );
      final result = await compact(0);
      expect(result?.goal, 'Exact raw user goal 保留约束');
      expect(result?.sourceVersion, 'memory-v1');
      expect(provider.selected?.maxOutputTokens, 1000);
      expect(provider.selected?.allowReasoningRetry, false);
      expect(provider.selected?.modelFallbacks, isEmpty);
      expect(
        provider.messages.every(
          (message) =>
              message.reasoningContent == null && !message.hasImageParts,
        ),
        true,
      );
      expect(
        provider.messages.fold<int>(
          0,
          (total, message) => total + utf8.encode(message.content).length,
        ),
        lessThanOrEqualTo(4096),
      );
      expect(await compact(1), isNull);
      expect(await compact(4), isNotNull);
      expect(await compact(8), isNull);
      expect(provider.calls, 2);
      expect(service.attempts('t'), 2);
      expect(token.isCancelled, false);
      token.cancel();
    },
  );
  test(
    'truncated valid JSON never replaces memory and oversized raw goal is not clipped',
    () async {
      final service = PublicContextCompactor(),
          provider = _Recorder()..finish = 'length';
      final token = CancelToken();
      Future<PublicContextCheckpoint?> compact(String id, String goal) =>
          service.compact(
            taskId: id,
            sourceVersion: 'rev',
            round: 0,
            estimatedTokens: 3000,
            inputBudgetTokens: 4096,
            historyCount: 50,
            goal: goal,
            publicText: 'Public tools only',
            config: config,
            provider: provider,
            cancelToken: token,
          );
      expect(await compact('partial', 'goal'), isNull);
      expect(token.isCancelled, false);
      expect(await compact('large', 'x' * 5000), isNull);
      expect(provider.calls, 1);
      token.cancel();
    },
  );
  test(
    'small input budgets skip paid request and non-cancel-aware source cannot hold compactor',
    () async {
      final small = PublicContextCompactor(),
          unused = _Recorder(),
          root = CancelToken();
      expect(
        await small.compact(
          taskId: 'small',
          sourceVersion: 'v',
          round: 0,
          estimatedTokens: 90,
          inputBudgetTokens: 100,
          historyCount: 50,
          goal: 'goal',
          publicText: 'public',
          config: config,
          provider: unused,
          cancelToken: root,
        ),
        isNull,
      );
      expect(unused.calls, 0);
      final bounded = PublicContextCompactor(
        requestTimeout: const Duration(milliseconds: 20),
      );
      final provider = _IgnoringCancellation(), timer = Stopwatch()..start();
      expect(
        await bounded.compact(
          taskId: 'timeout',
          sourceVersion: 'v',
          round: 0,
          estimatedTokens: 3000,
          inputBudgetTokens: 4096,
          historyCount: 50,
          goal: 'goal',
          publicText: 'public',
          config: config,
          provider: provider,
          cancelToken: root,
        ),
        isNull,
      );
      expect(timer.elapsed, lessThan(const Duration(seconds: 1)));
      expect(root.isCancelled, false);
      expect(provider.token?.isCancelled, true);
      await Future<void>.delayed(Duration.zero);
      expect(provider.cancellationRequested, true);
      root.cancel();
    },
  );
}
