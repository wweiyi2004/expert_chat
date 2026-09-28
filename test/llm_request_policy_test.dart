import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/llm/llm_request_policy.dart';
import 'package:flutter_test/flutter_test.dart';

const deepseek = LlmConfig(
  baseUrl: 'https://api.deepseek.com',
  apiKey: 'test',
  model: KnownModels.flash,
  serverWebSearch: true,
  forceServerWebSearch: true,
);
const tool = ToolSpec(name: 'fetch_url', description: 'Fetch', parameters: {});

void main() {
  test('hybrid thinking keeps the selected model, dual models switch', () {
    expect(
      LlmRequestPolicy.selectModel(
        selected: deepseek,
        reasonerModel: KnownModels.reasoner,
        thinking: true,
      ),
      same(deepseek),
    );
    final other = deepseek.copyWith(
      baseUrl: 'https://api.example.com',
      model: 'gpt-4o',
    );
    expect(
      LlmRequestPolicy.selectModel(
        selected: other,
        reasonerModel: 'o1',
        thinking: false,
      ),
      same(other),
    );
    final selected = LlmRequestPolicy.selectModel(
      selected: other,
      reasonerModel: 'o1',
      thinking: true,
    );
    expect(selected.model, 'o1');
    expect(selected.capabilities.supportsTools, isFalse);
    expect(selected.baseUrl, other.baseUrl);
  });

  test(
    'image turns preserve native vision unless a fallback is configured',
    () {
      final selected = deepseek.copyWith(model: 'gpt-4o');
      for (final fallback in [false, true]) {
        final config = LlmRequestPolicy.selectModel(
          selected: selected,
          reasonerModel: 'o1',
          thinking: true,
          hasImages: true,
          hasVisionFallback: fallback,
        );
        expect(config.model, fallback ? 'o1' : 'gpt-4o');
      }
    },
  );

  test('manual then saved choices precede the DeepSeek prose default', () {
    ReasoningEffort effort({
      LlmConfig config = deepseek,
      bool saved = false,
      bool prose = true,
      bool work = false,
      ReasoningEffort? manual,
    }) => LlmRequestPolicy.selectEffort(
      config: config,
      savedEffort: ReasoningEffort.high,
      hasSavedOverride: saved,
      proseTask: prose,
      workMode: work,
      manualEffort: manual,
    );
    expect(effort(), ReasoningEffort.low);
    expect(effort(saved: true), ReasoningEffort.high);
    expect(
      effort(saved: true, manual: ReasoningEffort.max),
      ReasoningEffort.max,
    );
    expect(effort(prose: false), ReasoningEffort.high);
    expect(effort(work: true), ReasoningEffort.high);
    expect(
      effort(
        config: deepseek.copyWith(
          baseUrl: 'https://example.com',
          model: 'gpt-4o',
        ),
      ),
      ReasoningEffort.high,
    );
  });

  LlmRoundRequest round({
    int index = 0,
    bool finalizing = false,
    bool thinking = true,
    bool enableTools = true,
    LlmConfig config = deepseek,
  }) => LlmRequestPolicy.forRound(
    config: config,
    thinking: thinking,
    reasoningEffort: ReasoningEffort.max,
    tools: const [tool],
    enableTools: enableTools,
    round: index,
    maxRounds: 3,
    finalizing: finalizing,
    forceToolName: tool.name,
  );

  test('forced tools and hosted search are forced only in the first round', () {
    final first = round();
    expect(first.config, same(deepseek));
    expect(first.tools, [tool]);
    expect(first.forceToolName, tool.name);
    expect(first.reasoningEffort, ReasoningEffort.max);
    final next = round(index: 1);
    expect(next.config.serverWebSearch, isTrue);
    expect(next.config.forceServerWebSearch, isFalse);
    expect(next.tools, [tool]);
    expect(next.forceToolName, isNull);
    expect(round(index: 2).tools, isNull);
    expect(round(index: 2).forceToolName, isNull);
    expect(round(thinking: false).reasoningEffort, isNull);
  });

  test('budget wrap-up drops all tool requests, thinking and nested retry', () {
    final last = round(finalizing: true);
    expect(last.config.serverWebSearch, isFalse);
    expect(last.config.forceServerWebSearch, isFalse);
    expect(last.config.allowReasoningRetry, isFalse);
    expect(last.tools, isNull);
    expect(last.forceToolName, isNull);
    expect(last.thinking, isFalse);
    expect(last.reasoningEffort, isNull);
    expect(
      LlmRequestPolicy.reasoningAttempt(
        config: last.config,
        attempt: 0,
        thinking: last.thinking,
        reasoningEffort: last.reasoningEffort,
      ).mayRetry,
      isFalse,
    );
  });

  test('disabled or unsupported tools cannot be forced into a request', () {
    for (final request in [
      round(enableTools: false),
      round(config: deepseek.copyWith(model: 'unknown-model')),
    ]) {
      expect(request.tools, isNull);
      expect(request.forceToolName, isNull);
    }
    expect(LlmRequestPolicy.canUseTools(deepseek, null), isFalse);
    expect(LlmRequestPolicy.canUseTools(deepseek, []), isFalse);
  });

  test('document forcing has priority over image and search forcing', () {
    expect(
      LlmRequestPolicy.forcedToolChoice(
        documentTool: 'edit_document',
        imageTool: 'image',
        searchTool: 'search',
      ),
      'edit_document',
    );
    expect(
      LlmRequestPolicy.forcedToolChoice(
        imageTool: 'image',
        searchTool: 'search',
      ),
      kToolChoiceRequired,
    );
    expect(LlmRequestPolicy.forcedToolChoice(), isNull);
  });

  test('reasoning limits scale by effort and recovery remains bounded', () {
    for (final (effort, seconds, chars) in [
      (ReasoningEffort.low, 30, 6000),
      (ReasoningEffort.high, 60, 12000),
      (ReasoningEffort.max, 120, 24000),
    ]) {
      final first = LlmRequestPolicy.reasoningAttempt(
        config: deepseek,
        attempt: 0,
        thinking: true,
        reasoningEffort: effort,
      );
      expect(first.timeout, Duration(seconds: seconds));
      expect(first.charLimit, chars);
      expect(first.mayRetry, isTrue);
      final recovery = LlmRequestPolicy.reasoningAttempt(
        config: deepseek,
        attempt: 1,
        thinking: true,
        reasoningEffort: effort,
      );
      expect(recovery.timeout, const Duration(seconds: 20));
      expect(recovery.charLimit, 4000);
      expect(recovery.thinking, isFalse);
      expect(recovery.reasoningEffort, isNull);
      expect(recovery.config.forceServerWebSearch, isFalse);
      expect(recovery.mayRetry, isFalse);
    }
  });
}
