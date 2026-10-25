import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/workbench/agents/role_trial_validator.dart';
import 'capability_evolution_test.dart' show FakeLlm;

void main() {
  const config = LlmConfig(
    baseUrl: 'https://not-used.invalid',
    apiKey: 'unused',
    model: 'reviewer',
  );
  const result =
      'The command exited successfully and the requested behavior is observed.';
  final hash = sha256.convert(utf8.encode(result)).toString();
  test(
    'execution role cannot self-verify prose without actual host tool evidence',
    () async {
      var calls = 0;
      final token = CancelToken();
      final provider = FakeLlm((_) async* {
        calls++;
        yield const ChatChunk(
          contentDelta:
              '{"pass":true,"criteria":"would be unsafe","limitations":""}',
          finishReason: 'stop',
        );
      });
      final verdict = await RoleTrialValidator().review(
        settings: const RoleValidationConfig(enabled: true),
        taskId: 't',
        candidateId: 'c',
        version: 1,
        scope: 'testing',
        instructions: 'Run actual tests',
        task: 'verify fixture',
        result: result,
        expectedHash: hash,
        evidenceHash: 'host1',
        acceptanceCriteria: 'Fixture must return exact expected value',
        requiresExecutionEvidence: true,
        config: config,
        provider: provider,
        token: token,
      );
      expect(verdict, isNull);
      expect(calls, 0);
      token.cancel();
    },
  );
  test(
    'real host evidence and pretrial criteria bound verdict; duplicate bounded',
    () async {
      final validator = RoleTrialValidator();
      var calls = 0;
      final token = CancelToken();
      final provider = FakeLlm((selected) async* {
        calls++;
        expect(selected.allowReasoningRetry, false);
        yield const ChatChunk(
          contentDelta:
              '{"pass":true,"criteria":"Host exit status and expected value both match","limitations":"Only this fixture was tested"}',
          finishReason: 'stop',
        );
      });
      Future<RoleValidationVerdict?> review() => validator.review(
        settings: const RoleValidationConfig(enabled: true),
        taskId: 't',
        candidateId: 'c',
        version: 2,
        scope: 'testing',
        instructions: 'Run actual tests',
        task: 'verify fixture',
        result: result,
        expectedHash: hash,
        evidenceHash: 'host2',
        acceptanceCriteria: 'Fixture must return expected value 42',
        requiresExecutionEvidence: true,
        toolEvidence: [
          {'exit_code': 0, 'result': '42'},
        ],
        config: config,
        provider: provider,
        token: token,
      );
      final verdict = await review();
      expect(verdict?.passed, true);
      expect(verdict?.evidenceHash, 'host2');
      expect(await review(), isNull);
      expect(calls, 1);
      token.cancel();
    },
  );
  test('partial valid JSON and incorrect result hashes never validate', () async {
    final token = CancelToken();
    var calls = 0;
    final provider = FakeLlm((_) async* {
      calls++;
      yield const ChatChunk(
        contentDelta:
            '{"pass":true,"criteria":"looks complete but stream truncated","limitations":""}',
        finishReason: 'length',
      );
    });
    final validator = RoleTrialValidator();
    Future<RoleValidationVerdict?> review(String expected) => validator.review(
      settings: const RoleValidationConfig(enabled: true),
      taskId: 't',
      candidateId: 'c',
      version: 1,
      scope: 'writing',
      instructions: 'Write a paragraph',
      task: 'write',
      result: result,
      expectedHash: expected,
      evidenceHash: 'hash',
      acceptanceCriteria: 'A complete paragraph',
      config: config,
      provider: provider,
      token: token,
    );
    expect(await review('wrong'), isNull);
    expect(calls, 0);
    expect(await review(hash), isNull);
    expect(calls, 1);
    token.cancel();
  });
}
