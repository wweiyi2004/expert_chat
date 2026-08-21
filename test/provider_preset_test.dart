import 'package:expert_chat/data/provider_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('built-in presets keep unique names and valid endpoints', () {
    final names = ProviderPreset.presets.map((p) => p.name).toList();
    expect(names.toSet().length, names.length);
    expect(ProviderPreset.presets.length, greaterThanOrEqualTo(35));

    for (final preset in ProviderPreset.presets) {
      expect(preset.baseUrl, isNotEmpty, reason: preset.name);
      expect(preset.chatModel, isNotEmpty, reason: preset.name);
      expect(preset.models, contains(preset.chatModel), reason: preset.name);
      expect(
        preset.models,
        contains(preset.reasonerModel),
        reason: preset.name,
      );
      final uri = Uri.parse(preset.baseUrl);
      expect(uri.hasScheme, isTrue, reason: preset.name);
      expect(
        {'http', 'https'}.contains(uri.scheme),
        isTrue,
        reason: '${preset.name} ${preset.baseUrl}',
      );
      if (preset.group == ProviderPresetGroup.local) {
        expect(uri.host, anyOf('127.0.0.1', 'localhost'), reason: preset.name);
      } else {
        expect(uri.scheme, 'https', reason: preset.name);
      }
    }
  });

  test('original five vendors stay in the catalog', () {
    final byName = {for (final p in ProviderPreset.presets) p.name: p};
    expect(byName['DeepSeek']!.baseUrl, 'https://api.deepseek.com');
    expect(
      byName['DeepSeek']!.models,
      contains('deepseek-v4-flash-vision-exp'),
    );
    expect(byName['Grok (xAI)']!.baseUrl, 'https://api.x.ai/v1');
    expect(byName['OpenAI']!.baseUrl, 'https://api.openai.com/v1');
    expect(byName['Kimi (Moonshot)']!.baseUrl, 'https://api.moonshot.cn/v1');
    expect(byName['智谱 GLM']!.baseUrl, 'https://open.bigmodel.cn/api/paas/v4');
    expect(byName['讯飞星火']!.baseUrl, 'https://spark-api-open.xf-yun.com/v1');
    expect(
      byName['GitHub Models']!.baseUrl,
      'https://models.github.ai/inference',
    );
    expect(byName['llama.cpp']!.baseUrl, 'http://127.0.0.1:8080/v1');
  });

  test('search matches vendor, url and model ids', () {
    expect(
      ProviderPreset.presets.where((p) => p.matchesQuery('硅基')).single.name,
      '硅基流动 SiliconFlow',
    );
    expect(
      ProviderPreset.presets.any((p) => p.matchesQuery('openrouter')),
      isTrue,
    );
    expect(ProviderPreset.presets.any((p) => p.matchesQuery('11434')), isTrue);
    expect(
      ProviderPreset.presets.where((p) => p.matchesQuery('zzzz-nope')),
      isEmpty,
    );
  });

  test('each catalog group has presets', () {
    for (final group in ProviderPresetGroup.values) {
      expect(
        ProviderPreset.presets.where((p) => p.group == group),
        isNotEmpty,
        reason: group.label,
      );
    }
  });
}
