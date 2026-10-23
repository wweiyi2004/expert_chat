import 'package:expert_chat/data/context_prefs.dart';
import 'package:expert_chat/data/model_token_limits.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_state.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/model_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'legacy output larger than window cannot collapse input budget to 1K',
    () {
      const settings = SettingsState(
        context: ContextPrefs(
          contextWindowTokens: 256000,
          maxOutputTokens: 393216,
        ),
      );
      final effective = effectiveContextPrefs(settings, settings.config);
      expect(effective.inputBudgetTokens, 223232);
      expect(effective.maxOutputTokens, 32768);
    },
  );

  test(
    'same model on two endpoints keeps independent limits and overrides',
    () {
      final settings = SettingsState(
        profiles: [
          for (final (id, window, output) in [
            ('a', 128000, 16000),
            ('b', 1000000, 64000),
          ])
            ProviderProfile(
              id: id,
              name: id,
              baseUrl: 'https://$id.test/v1',
              chatModel: 'shared-model',
              reasonerModel: 'shared-model',
              modelLimits: {
                'shared-model': ModelTokenLimits(
                  contextWindowTokens: window,
                  maxOutputTokens: output,
                ),
              },
            ),
        ],
        modelContexts: {
          modelContextKey(
            'https://a.test/v1/',
            'shared-model',
          ): const ContextPrefs(
            contextWindowTokens: 200000,
            maxOutputTokens: 32000,
          ),
        },
      );
      ContextPrefs prefs(String id) => effectiveContextPrefs(
        settings,
        LlmConfig(
          baseUrl: 'https://$id.test/v1',
          apiKey: '',
          model: 'shared-model',
          profileId: id,
        ),
      );
      expect(prefs('a').contextWindowTokens, 128000);
      expect(prefs('a').maxOutputTokens, 16000);
      expect(prefs('b').contextWindowTokens, 1000000);
      expect(prefs('b').maxOutputTokens, 0);
    },
  );

  test(
    'split input/output metadata preserves the input ceiling and unknown stays unknown',
    () {
      final split = ModelTokenLimits.fromModelApi({
        'inputTokenLimit': 1048576,
        'outputTokenLimit': 65536,
      });
      expect(split.contextWindowTokens, 1114112);
      expect(split.inputLimitTokens, 1048576);
      expect(ModelTokenLimits.fromModelApi({'id': 'unknown'}).isKnown, isFalse);
      expect(
        const ContextPrefs(inputLimitTokens: -1).inputBudgetTokens,
        greaterThan(0),
      );
    },
  );
}
