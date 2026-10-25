import 'package:expert_chat/core/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/work_agents.dart';
import '../../../state/settings_controller.dart';
import '../../../state/model_service_routing.dart';
import '../../../state/conversation_model_choice.dart';
import '../../../domain/llm/llm_provider.dart';

class WorkAgentModelPoolSettings extends ConsumerWidget {
  const WorkAgentModelPoolSettings({super.key, this.conversationId});
  final String? conversationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    if (settings == null) return const SizedBox.shrink();
    final choice = conversationId == null
        ? null
        : ref.watch(conversationModelChoiceProvider)[conversationId];
    final defaultModel = choice == null || choice == autoModelChoice
        ? settings.model
        : choice;
    final configured = ref.watch(workAgentModelPoolProvider);
    final selected = configured ?? [WorkAgentModelOption(defaultModel)];
    final catalog =
        {
            ...serviceModelCatalog(settings.profiles),
            defaultModel,
            ...selected.map((m) => m.model),
          }.where((id) => ModelCapabilities.resolve(id).supportsTools).toList()
          ..sort();
    return ListTile(
      dense: true,
      leading: const Icon(Icons.model_training_outlined, size: 19),
      title: const Text('子代理可用模型'),
      subtitle: Text(
        configured == null
            ? conversationId == null
                  ? '默认跟随各主任务的模型 · 可单独选择全局模型池'
                  : '默认使用当前会话模型 · 可添加其他模型'
            : selected.isEmpty
            ? '未选择模型，暂不创建子代理'
            : selected.map((m) => m.model).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.tune, size: 18),
      onTap: () async {
        final result = await showDialog<List<WorkAgentModelOption>>(
          context: context,
          builder: (_) => _PoolDialog(
            models: catalog,
            selected: selected,
            followsTask: configured == null && conversationId == null,
          ),
        );
        if (result == null) return;
        try {
          await ref.read(workAgentModelPoolProvider.notifier).save(result);
        } catch (error) {
          if (context.mounted) {
            AppToastMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('$error')));
          }
        }
      },
    );
  }
}

class _PoolDialog extends StatefulWidget {
  const _PoolDialog({
    required this.models,
    required this.selected,
    this.followsTask = false,
  });
  final bool followsTask;
  final List<String> models;
  final List<WorkAgentModelOption> selected;
  @override
  State<_PoolDialog> createState() => _PoolDialogState();
}

class _PoolDialogState extends State<_PoolDialog> {
  late final Map<String, WorkAgentModelOption> _selected = {
    for (final m in widget.selected) m.model: m,
  };
  String _query = '';
  Future<void> _editPurpose(String model) async {
    var purpose = _selected[model]?.purpose ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(model, maxLines: 2),
        content: TextFormField(
          initialValue: purpose,
          maxLength: 240,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '适合的任务',
            hintText: '例如：复杂代码审计、快速检索、界面实现',
          ),
          onChanged: (value) => purpose = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, purpose.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      setState(
        () => _selected[model] = WorkAgentModelOption(model, purpose: result),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.models
        .where((m) => m.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: const Text('子代理可用模型'),
      content: SizedBox(
        width: 500,
        height: MediaQuery.sizeOf(context).height * .52,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.followsTask)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '当前未单独配置：子代理跟随各自主任务的模型。下方勾选展示全局默认模型；保存后才成为固定的全局模型池。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            const Text(
              '主模型会看到这些模型及用途，并按任务选择。未加入池中的模型不可用于新子代理。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索模型',
              ),
              onChanged: (q) => setState(() => _query = q),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) {
                  final model = visible[i];
                  final chosen = _selected.containsKey(model);
                  final purpose = _selected[model]?.purpose ?? '';
                  return CheckboxListTile(
                    value: chosen,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: purpose.isEmpty
                        ? null
                        : Text(
                            purpose,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                    secondary: chosen
                        ? IconButton(
                            tooltip: '设置适合的任务',
                            icon: const Icon(Icons.edit_note, size: 20),
                            onPressed: () => _editPurpose(model),
                          )
                        : null,
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected[model] = WorkAgentModelOption(model);
                      } else {
                        _selected.remove(model);
                      }
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.values.toList()),
          child: Text('保存 · ${_selected.length} 个模型'),
        ),
      ],
    );
  }
}
