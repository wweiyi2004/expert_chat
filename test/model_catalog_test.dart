import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('built-in registry normalizes aggregator prefixes and case', () {
    for (final entry in ModelCatalog.entries.entries) {
      expect(ModelCapabilities.resolve(entry.key), same(entry.value));
      expect(
        ModelCapabilities.resolve('vendor/${entry.key.toUpperCase()}'),
        same(entry.value),
      );
    }
    final preset = ProviderPreset.presets.firstWhere(
      (p) => p.name == 'DeepSeek',
    );
    expect(preset.models, same(KnownModels.all));
    expect(preset.chatModel, KnownModels.chat);
    expect(preset.reasonerModel, KnownModels.reasoner);
    for (final model in KnownModels.all) {
      expect(ModelCatalog.entries.containsKey(model), isTrue);
    }
  });

  test('unregistered models retain conservative compatibility heuristics', () {
    for (final id in ['custom-model', 'vendor/unknown-reasoner']) {
      final caps = ModelCapabilities.resolve(id);
      expect(caps.supportsTools, isFalse);
      expect(caps.supportsVision, isFalse);
      expect(caps.sendThinkingField, isFalse);
    }
    expect(ModelCapabilities.resolve('qwen/qwen3-max').supportsTools, isTrue);
    expect(ModelCapabilities.resolve('gpt-4o').supportsVision, isTrue);
    expect(ModelCapabilities.resolve('grok-4.5-latest').isReasoner, isTrue);
  });

  test(
    'explicit capability overrides survive copies; inferred ones re-resolve',
    () {
      const override = ModelCapabilities(
        isReasoner: false,
        supportsTools: false,
        sendThinkingField: false,
        supportsVision: false,
      );
      const inferred = LlmConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: 'test',
        model: KnownModels.flash,
      );
      expect(inferred.capabilities.supportsVision, isTrue);
      expect(
        inferred
            .copyWith(model: KnownModels.reasoner)
            .capabilities
            .supportsVision,
        isFalse,
      );
      final explicit = inferred.copyWith(capabilities: override);
      expect(
        explicit.copyWith(model: KnownModels.reasoner).capabilities,
        same(override),
      );
    },
  );

  test(
    'provider identity distinguishes endpoints from aggregator model names',
    () {
      expect(
        ModelCatalog.isOfficialDeepSeekEndpoint('https://api.deepseek.com/v1'),
        isTrue,
      );
      expect(
        ModelCatalog.isOfficialDeepSeekEndpoint(
          'https://api.deepseek.com.example',
        ),
        isFalse,
      );
      expect(
        ModelCatalog.isDeepSeek(
          baseUrl: 'https://gateway.example.com',
          model: 'deepseek-ai/DeepSeek-V4',
        ),
        isTrue,
      );
      expect(
        ModelCatalog.isDeepSeek(
          baseUrl: 'https://gateway.example.com',
          model: 'custom-model',
        ),
        isFalse,
      );
    },
  );
}
