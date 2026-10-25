import 'package:expert_chat/core/app_toast.dart';
import 'text_value_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../state/model_route_groups.dart';
import '../../../state/model_service_routing.dart';
import '../../../state/settings_controller.dart';

class ModelRouteGroupsPanel extends ConsumerWidget {
  const ModelRouteGroupsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(modelRouteGroupsProvider);
    final catalog = serviceModelCatalog(
      ref.watch(settingsControllerProvider).value?.profiles ?? [],
    );
    Future<void> save(List<ModelRouteGroup> groups, {String? autoGroup}) async {
      try {
        await ref
            .read(modelRouteGroupsProvider.notifier)
            .save(groups, autoGroup: autoGroup);
      } catch (error) {
        if (context.mounted) {
          AppToastMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }

    return ExpansionTile(
      title: const Text('模型路由组与 Auto 策略'),
      subtitle: const Text('先同模型渠道切换，再按用户启用策略切换模型；部分输出后不重发'),
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: DropdownButtonFormField<String>(
            key: ValueKey(policy.autoGroup),
            initialValue: policy.groups.any((g) => g.id == policy.autoGroup)
                ? policy.autoGroup
                : '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Auto 模型范围'),
            items: [
              const DropdownMenuItem(value: '', child: Text('全部已配置模型，按能力选择')),
              for (final group in policy.groups)
                DropdownMenuItem(value: group.id, child: Text(group.name)),
            ],
            onChanged: (id) {
              if (id != null) save(policy.groups, autoGroup: id);
            },
          ),
        ),
        for (final group in policy.groups)
          ExpansionTile(
            title: Text(group.name),
            subtitle: Text(group.models.join(' → ')),
            children: [
              SwitchListTile(
                title: const Text('允许该组在首次响应前切换到不同模型'),
                subtitle: const Text(
                  '仅明确限流/配额/不可用等失败；工具往返开始后不跨模型重放。关闭时只选首个符合能力的模型。',
                ),
                value: group.failover,
                onChanged: (enabled) => save([
                  for (final item in policy.groups)
                    if (item.id == group.id)
                      ModelRouteGroup(
                        id: item.id,
                        name: item.name,
                        models: item.models,
                        failover: enabled,
                      )
                    else
                      item,
                ]),
              ),
              for (var i = 0; i < group.models.length; i++)
                ListTile(
                  title: Text('${i + 1}. ${group.models[i]}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '提高模型优先级',
                        onPressed: i == 0
                            ? null
                            : () {
                                final models = [...group.models];
                                final moved = models.removeAt(i);
                                models.insert(i - 1, moved);
                                save([
                                  for (final item in policy.groups)
                                    if (item.id == group.id)
                                      ModelRouteGroup(
                                        id: item.id,
                                        name: item.name,
                                        models: models,
                                        failover: item.failover,
                                      )
                                    else
                                      item,
                                ]);
                              },
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        tooltip: '移除此模型',
                        onPressed: group.models.length < 2
                            ? null
                            : () => save([
                                for (final item in policy.groups)
                                  if (item.id == group.id)
                                    ModelRouteGroup(
                                      id: item.id,
                                      name: item.name,
                                      models: item.models
                                          .where((m) => m != group.models[i])
                                          .toList(),
                                      failover: item.failover,
                                    )
                                  else
                                    item,
                              ]),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
                ),
              Wrap(
                children: [
                  for (final model in catalog.where(
                    (m) => !group.models.contains(m),
                  ))
                    TextButton(
                      onPressed: () => save([
                        for (final item in policy.groups)
                          if (item.id == group.id)
                            ModelRouteGroup(
                              id: item.id,
                              name: item.name,
                              models: [...item.models, model],
                              failover: item.failover,
                            )
                          else
                            item,
                      ]),
                      child: Text('+ $model'),
                    ),
                ],
              ),
              TextButton(
                onPressed: () => save(
                  policy.groups.where((g) => g.id != group.id).toList(),
                  autoGroup: policy.autoGroup == group.id ? '' : null,
                ),
                child: const Text('删除路由组'),
              ),
            ],
          ),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('创建模型路由组'),
          onPressed: catalog.isEmpty
              ? null
              : () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (_) => const TextValueDialog(
                      title: '创建路由组',
                      initialText: '',
                      label: '路由组名称',
                      maxLines: 1,
                      maxLength: 120,
                    ),
                  );
                  if (result != null && result.isNotEmpty) {
                    await save([
                      ...policy.groups,
                      ModelRouteGroup(
                        id: const Uuid().v4(),
                        name: result,
                        models: [catalog.first],
                      ),
                    ]);
                  }
                },
        ),
      ],
    );
  }
}
