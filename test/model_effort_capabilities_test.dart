import 'package:expert_chat/data/model_token_limits.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_state.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/features/chat/widgets/reasoning_effort_control.dart';
import 'package:expert_chat/state/conversation_model_choice.dart';
import 'package:expert_chat/state/model_context.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'GPT6 offers separate off toggle and five actual strength positions',
    (tester) async {
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReasoningEffortSlider(
              config: const LlmConfig(
                baseUrl: 'https://source.invalid',
                apiKey: 'fixture',
                model: 'gpt-6-sol',
              ),
              thinking: true,
              effort: ReasoningEffort.high,
              supportsEffort: true,
              onToggle: () => toggles++,
            ),
          ),
        ),
      );
      expect(tester.widget<Slider>(find.byType(Slider)).divisions, 4);
      await tester.tap(find.byKey(const ValueKey('reasoning-thinking-toggle')));
      await tester.pump();
      expect(toggles, 1);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('reasoning-thinking-toggle')),
            )
            .value,
        false,
      );
    },
  );

  test(
    'official GPT6 auto uses Responses while explicit source formats stay unchanged',
    () {
      const config = LlmConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'fixture',
        model: 'gpt-6.1-sol',
      );
      expect(config.effectiveApiFormat, LlmApiFormat.openAiResponses);
      expect(
        config
            .copyWith(apiFormat: LlmApiFormat.openAiCompatible)
            .effectiveApiFormat,
        LlmApiFormat.openAiCompatible,
      );
      expect(
        config.copyWith(baseUrl: 'https://gateway.invalid').effectiveApiFormat,
        LlmApiFormat.openAiCompatible,
      );
      expect(ModelCapabilities.resolve('gpt-6.1-sol').supportsVision, true);
    },
  );

  test('specific GPT generations retain their actual effort sets', () {
    expect(ModelCatalog.reasoningEfforts('gpt-6.1-sol'), [
      'low',
      'medium',
      'high',
      'xhigh',
      'max',
    ]);
    expect(ModelCatalog.reasoningEfforts('gpt-5.2'), [
      'low',
      'medium',
      'high',
      'xhigh',
    ]);
    expect(ModelCatalog.reasoningEfforts('gpt-5.1'), ['low', 'medium', 'high']);
    expect(
      ModelCapabilities.resolve('gpt-6.1-sol').reasoningCanBeDisabled,
      false,
    );
    expect(ModelCapabilities.resolve('gpt-6-sol').reasoningCanBeDisabled, true);
    expect(ModelCapabilities.resolve('gpt-4o').supportsReasoningEffort, false);
    expect(
      ModelCapabilities.resolve('gpt-unknown').supportsReasoningEffort,
      false,
    );
  });
  test(
    'reported per-source levels override catalog and survive profile JSON',
    () {
      final metadata = ModelTokenLimits.fromModelApi({
        'supported_reasoning_levels': [
          {'effort': 'none'},
          {'effort': 'medium'},
          {'effort': 'high'},
        ],
      });
      final original = ProviderProfile(
        id: 'source',
        name: 'fixture',
        baseUrl: 'https://source.invalid',
        chatModel: 'gpt-6.1-sol',
        reasonerModel: 'gpt-6.1-sol',
        modelLimits: {'gpt-6.1-sol': metadata},
      );
      final profile = ProviderProfile.fromJson(original.toJson());
      final settings = SettingsState(
        profiles: [profile],
        activeProfileId: 'source',
        apiKey: 'fixture',
      );
      final config = applyReportedModelCapabilities(
        settings,
        const LlmConfig(
          profileId: 'source',
          baseUrl: 'https://source.invalid',
          apiKey: 'fixture',
          model: 'gpt-6.1-sol',
        ),
      );
      expect(reasoningEffortsFor(config), [
        ReasoningEffort.medium,
        ReasoningEffort.high,
      ]);
      expect(config.capabilities.reasoningCanBeDisabled, true);
      expect(reasoningEffortWire(config, ReasoningEffort.max), 'high');
      expect(profile.modelLimits['gpt-6.1-sol']!.reasoningEfforts, [
        'medium',
        'high',
      ]);
    },
  );
  test(
    'source choice encodes opaque model and profile ids without collision',
    () {
      final source = parseModelSourceChoice(
        modelSourceChoice('profile:one', 'vendor/model:version'),
      )!;
      expect(source.profile, 'profile:one');
      expect(source.model, 'vendor/model:version');
      expect(parseModelSourceChoice('gpt-6.1-sol'), isNull);
    },
  );
  testWidgets(
    'GPT6.1 shows five independent strengths without unsupported off',
    (tester) async {
      ReasoningEffort? selected;
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReasoningEffortSlider(
              config: const LlmConfig(
                baseUrl: 'https://source.invalid',
                apiKey: 'fixture',
                model: 'gpt-6.1-sol',
              ),
              thinking: true,
              effort: ReasoningEffort.high,
              supportsEffort: true,
              onToggle: () => toggles++,
              onChanged: (value) => selected = value,
            ),
          ),
        ),
      );
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.divisions, 4);
      expect(slider.value, 2);
      expect(find.text('关闭'), findsNothing);
      slider.onChanged!(4);
      slider.onChangeEnd!(4);
      await tester.pump();
      expect(selected, ReasoningEffort.max);
      expect(toggles, 0);
      expect(find.text('最大'), findsWidgets);
    },
  );
}
