import 'package:expert_chat/data/model_token_limits.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/settings_state.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/state/model_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each listed model keeps its own reported efforts', () {
    // Levels as model discovery stores them from a provider's /models reply.
    final profile = ProviderProfile(
      name: 'Gateway',
      baseUrl: 'https://gateway.example.com/v1',
      chatModel: 'alpha',
      reasonerModel: 'alpha',
      models: const ['alpha', 'beta'],
      modelLimits: const {
        'alpha': ModelTokenLimits(reasoningEfforts: ['low', 'high']),
        'beta': ModelTokenLimits(reasoningEfforts: ['minimal', 'medium']),
      },
    );
    final settings = SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: 'sk-test',
    );
    List<String> efforts(LlmConfig config) =>
        reasoningEffortsFor(config).map((e) => e.wire).toList();

    // The active config pins alpha's reported capabilities; a bare
    // copyWith(model:) carries them over to every other model.
    expect(efforts(settings.config.copyWith(model: 'beta')), ['low', 'high']);

    final derived = applyReportedModelCapabilities(
      settings,
      settings.config.copyWith(model: 'beta', profileId: profile.id),
    );
    expect(efforts(derived), ['minimal', 'medium']);
  });
}
