import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/prompt_presets.dart';
import '../../state/settings_controller.dart';

class PromptPresetPicker extends ConsumerWidget {
  const PromptPresetPicker({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(
      settingsControllerProvider.select((s) => s.value?.promptPresets),
    );
    return PopupMenuButton<String>(
      tooltip: '切换提示词预设',
      icon: const Icon(Icons.tune_rounded),
      onSelected: (id) {
        if (id == '__manage') {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PromptPresetsPage()),
          );
        } else {
          ref
              .read(settingsControllerProvider.notifier)
              .selectPromptPreset(id == '__auto' ? null : id);
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: '__auto',
          checked: presets?.active == null,
          child: const Text('自动选择技能'),
        ),
        for (final item in presets?.items ?? const <PromptPreset>[])
          CheckedPopupMenuItem(
            value: item.id,
            checked: presets?.activeId == item.id,
            child: Text(item.name),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '__manage', child: Text('管理提示词预设')),
      ],
    );
  }
}

class PromptPresetsPage extends ConsumerWidget {
  const PromptPresetsPage({super.key});
  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    PromptPreset? preset,
  ]) async {
    final name = TextEditingController(text: preset?.name);
    final prompt = TextEditingController(text: preset?.prompt);
    final form = GlobalKey<FormState>();
    final result = await showDialog<PromptPreset>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(preset == null ? '新建提示词预设' : '编辑提示词预设'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '名称'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请输入名称' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: prompt,
                    minLines: 6,
                    maxLines: 14,
                    decoration: const InputDecoration(labelText: '提示词'),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请输入提示词' : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  ctx,
                  PromptPreset(
                    id: preset?.id ?? const Uuid().v4(),
                    name: name.text.trim(),
                    prompt: prompt.text,
                    ownerId: preset?.ownerId ?? 'local',
                    updatedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
                  ),
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    prompt.dispose();
    if (result == null || !context.mounted) return;
    final current = ref.read(settingsControllerProvider).value!.promptPresets;
    await ref
        .read(settingsControllerProvider.notifier)
        .setPromptPresets(
          PromptPresets(
            activeId: current.activeId,
            items: [
              for (final item in current.items)
                if (item.id != result.id) item else result,
              if (!current.items.any((p) => p.id == result.id)) result,
            ],
          ),
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('提示词预设')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: settings.hasValue ? () => _edit(context, ref) : null,
        icon: const Icon(Icons.add),
        label: const Text('新建预设'),
      ),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (s) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            const Text('选择后用于后续普通聊天；正在生成的回复保留发送时的预设。预设随设置备份保存。'),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                title: const Text('自动选择技能'),
                leading: Icon(
                  s.promptPresets.active == null
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                onTap: () => ref
                    .read(settingsControllerProvider.notifier)
                    .selectPromptPreset(null),
              ),
            ),
            for (final item in s.promptPresets.items)
              Card(
                child: ListTile(
                  leading: Icon(
                    s.promptPresets.activeId == item.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    item.prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => ref
                      .read(settingsControllerProvider.notifier)
                      .selectPromptPreset(item.id),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'edit') {
                        await _edit(context, ref, item);
                        return;
                      }
                      if (action == 'copy') {
                        await _edit(
                          context,
                          ref,
                          PromptPreset(
                            id: const Uuid().v4(),
                            name: '${item.name} 副本',
                            prompt: item.prompt,
                            ownerId: item.ownerId,
                          ),
                        );
                        return;
                      }
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text('删除“${item.name}”？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('删除'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true || !context.mounted) return;
                      final latest = ref
                          .read(settingsControllerProvider)
                          .value!
                          .promptPresets;
                      await ref
                          .read(settingsControllerProvider.notifier)
                          .setPromptPresets(
                            PromptPresets(
                              activeId: latest.activeId == item.id
                                  ? null
                                  : latest.activeId,
                              items: latest.items
                                  .where((p) => p.id != item.id)
                                  .toList(),
                            ),
                          );
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'copy', child: Text('复制')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
