import 'package:expert_chat/core/app_toast.dart';
import 'text_value_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/role_validation_settings.dart';
import '../../../state/settings_controller.dart';
import '../../../state/model_service_routing.dart';
import '../../../domain/workbench/agents/role_trial_validator.dart';

class RoleValidationPanel extends ConsumerWidget {
  const RoleValidationPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(roleValidationSettingsProvider);
    final models = serviceModelCatalog(
      ref.watch(settingsControllerProvider).value?.profiles ?? [],
    );
    Future<void> save({
      bool? enabled,
      bool? promote,
      String? model,
      int? max,
      String? prompt,
    }) async {
      final current = ref.read(roleValidationSettingsProvider);
      try {
        await ref
            .read(roleValidationSettingsProvider.notifier)
            .save(
              RoleValidationConfig(
                enabled: enabled ?? current.enabled,
                autoPromote: promote ?? current.autoPromote,
                model: model ?? current.model,
                maxReviewsPerTask: max ?? current.maxReviewsPerTask,
                prompt: prompt ?? current.prompt,
              ),
            );
      } catch (error) {
        if (context.mounted) {
          AppToastMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }

    return ExpansionTile(
      title: const Text('角色证据自动验收（可选）'),
      subtitle: const Text('默认人工审阅；按实际试用结果版本验收，不能自授能力'),
      children: [
        SwitchListTile(
          title: const Text('启用模型证据验收'),
          value: value.enabled,
          onChanged: (v) => save(enabled: v),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<String>(
            key: ValueKey(value.model),
            initialValue:
                [
                  '__current__',
                  '__supervisor__',
                  ...models,
                ].contains(value.model)
                ? value.model
                : '__current__',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '验收模型'),
            items: [
              const DropdownMenuItem(
                value: '__current__',
                child: Text('跟随当前执行模型'),
              ),
              const DropdownMenuItem(
                value: '__supervisor__',
                child: Text('跟随已配置监督模型（未配置则不审查）'),
              ),
              for (final model in models)
                DropdownMenuItem(
                  value: model,
                  child: Text(model, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (m) {
              if (m != null) save(model: m);
            },
          ),
        ),
        SwitchListTile(
          title: const Text('验收通过后自动加入复用库'),
          subtitle: const Text('仅新增同版本、证据哈希匹配的角色；已存在的用户角色绝不自动覆盖。'),
          value: value.autoPromote,
          onChanged: value.enabled ? (v) => save(promote: v) : null,
        ),
        ListTile(
          title: Text(
            '每任务最多 ${value.maxReviewsPerTask} 次，单次最多 768 token / 30 秒',
          ),
          subtitle: Slider(
            value: value.maxReviewsPerTask.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            onChanged: (v) => save(max: v.round()),
          ),
        ),
        TextButton(
          onPressed: () async {
            final next = await showDialog<String>(
              context: context,
              builder: (_) => TextValueDialog(
                title: '角色验收指令',
                initialText: value.prompt,
                label: '验收指令',
                minLines: 4,
                maxLines: 10,
                maxLength: 16000,
              ),
            );
            if (next != null) await save(prompt: next);
          },
          child: const Text('编辑默认验收指令'),
        ),
        TextButton(
          onPressed: () => save(prompt: defaultRoleValidationPrompt),
          child: const Text('恢复默认验收指令'),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '模型审阅与用户验收分别标注。空输出、超过审阅上限、不完整响应、重复证据或过时版本不自动通过。模型审阅并非对未执行能力的证明；验收范围和限制保存在证据中，额外请求计入辅助用量。',
          ),
        ),
      ],
    );
  }
}
