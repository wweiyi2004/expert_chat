import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/supervisor_settings.dart';
import '../../../state/settings_controller.dart';
import '../../../state/model_service_routing.dart';
import '../../../domain/workbench/agents/task_supervisor.dart';

class SupervisorSettingsPanel extends ConsumerWidget {
  const SupervisorSettingsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(supervisorSettingsProvider);
    final profiles =
        ref.watch(settingsControllerProvider).value?.profiles ?? [];
    final models = serviceModelCatalog(profiles);
    Future<void> save({
      bool? enabled,
      String? model,
      int? maxReviews,
      int? minRoundGap,
      String? prompt,
    }) async {
      final current = ref.read(supervisorSettingsProvider);
      try {
        await ref
            .read(supervisorSettingsProvider.notifier)
            .save(
              SupervisorConfig(
                enabled: enabled ?? current.enabled,
                model: model ?? current.model,
                maxReviews: maxReviews ?? current.maxReviews,
                minRoundGap: minRoundGap ?? current.minRoundGap,
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
      title: const Text('可选监督模型'),
      subtitle: const Text('默认关闭 · 事件触发 · 下一完整工具轮生效 · 不增加权限'),
      children: [
        SwitchListTile(
          title: const Text('启用任务监督'),
          value: value.enabled,
          onChanged: (enabled) => save(enabled: enabled),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<String>(
            key: ValueKey('supervisor-${value.model}'),
            initialValue: models.contains(value.model) ? value.model : '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: '监督模型（显式选择）'),
            items: [
              const DropdownMenuItem(value: '', child: Text('未配置，不发起监督请求')),
              for (final model in models)
                DropdownMenuItem(
                  value: model,
                  child: Text(model, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (model) {
              if (model != null) save(model: model);
            },
          ),
        ),
        ListTile(
          title: Text('每任务最多 ${value.maxReviews} 次审查'),
          subtitle: Slider(
            value: value.maxReviews.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            onChanged: (next) => save(maxReviews: next.round()),
          ),
        ),
        ListTile(
          title: Text('审查间隔至少 ${value.minRoundGap} 个工具轮'),
          subtitle: Slider(
            value: value.minRoundGap.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            onChanged: (next) => save(minRoundGap: next.round()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: _SupervisorPromptEditor(
            key: ValueKey(value.prompt),
            prompt: value.prompt,
            onSave: (prompt) => save(prompt: prompt),
          ),
        ),
        TextButton(
          onPressed: () => save(prompt: defaultSupervisorPrompt),
          child: const Text('恢复默认监督指令'),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '只在能力缺口、重复失败或关键交付触发。最多输出 768 token，30 秒上限。只读取公开目标/计划/结果摘要/产物版本；建议过时即丢弃。工具建议由现有权限系统处理，模型建议从当前允许池选择。运行日志记录请求、采纳/丢弃和用量；是否提高质量仍需具体任务对照。',
          ),
        ),
      ],
    );
  }
}

class _SupervisorPromptEditor extends StatefulWidget {
  const _SupervisorPromptEditor({
    super.key,
    required this.prompt,
    required this.onSave,
  });
  final String prompt;
  final Future<void> Function(String) onSave;
  @override
  State<_SupervisorPromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_SupervisorPromptEditor> {
  late final _text = TextEditingController(text: widget.prompt);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _text,
        minLines: 3,
        maxLines: 8,
        decoration: const InputDecoration(labelText: '监督指令'),
        onChanged: (_) => setState(() {}),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: _text.text == widget.prompt
              ? null
              : () => widget.onSave(_text.text),
          child: const Text('保存监督指令'),
        ),
      ),
    ],
  );
}
