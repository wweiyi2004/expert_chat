import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/memory_controller.dart';
import '../../memory/memory_page.dart';

class MemorySettingsCard extends ConsumerWidget {
  const MemorySettingsCard({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(memoryControllerProvider);
    final count = memory.value?.entries.length;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.psychology_alt_outlined),
            title: const Text('启用长期记忆'),
            value: enabled,
            onChanged: onEnabledChanged,
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('管理记忆'),
            subtitle: Text(
              count == null ? '查看本地记忆文件' : '已保存 $count 条 · 可查看、编辑和删除',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const MemoryPage())),
          ),
        ],
      ),
    );
  }
}
