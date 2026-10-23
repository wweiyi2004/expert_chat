import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/settings_controller.dart';
import '../../../state/model_context.dart';
import 'context_settings_card.dart';

class ModelContextSettings extends ConsumerWidget {
  const ModelContextSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    if (settings == null) return const SizedBox.shrink();
    final config = settings.config;
    final prefs = effectiveContextPrefs(settings, config);
    final limits = reportedModelLimits(settings, config);
    final overridden = settings.modelContexts.containsKey(
      modelContextKey(config.baseUrl, config.model),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${config.model} · ${settings.active?.name ?? ''}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Text(
                limits?.isKnown == true
                    ? '服务上报：上下文 ${limits?.contextWindowTokens ?? '未提供'}，最大输出 ${limits?.maxOutputTokens ?? '未提供'} tokens。'
                    : '服务尚未上报额度。当前使用通用值；可重新扫描模型，或为此模型单独设置。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (overridden)
                TextButton(
                  onPressed: () => ref
                      .read(settingsControllerProvider.notifier)
                      .setModelContextPrefs(config.baseUrl, config.model, null),
                  child: const Text('恢复跟随服务额度'),
                ),
            ],
          ),
        ),
        ContextSettingsCard(
          prefs: prefs,
          maxWindowTokens: limits?.contextWindowTokens,
          maxOutputTokens: limits?.maxOutputTokens,
          onChanged: (value) async {
            try {
              await ref
                  .read(settingsControllerProvider.notifier)
                  .setModelContextPrefs(config.baseUrl, config.model, value);
            } catch (error) {
              if (context.mounted)
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('$error')));
            }
          },
        ),
      ],
    );
  }
}
