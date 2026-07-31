import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../domain/memory/memory_entry.dart';
import '../../domain/memory/memory_safety.dart';
import '../../domain/memory/memory_transfer.dart';
import '../../state/memory_controller.dart';
import 'memory_import_review_sheet.dart';

class MemoryPage extends ConsumerWidget {
  const MemoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncMemory = ref.watch(memoryControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('长期记忆'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '备份与恢复',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'export') {
                unawaited(_exportBackup(context, ref));
              } else if (value == 'import') {
                unawaited(_importBackup(context, ref));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'export',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.ios_share_outlined),
                  title: Text('导出记忆备份'),
                ),
              ),
              PopupMenuItem(
                value: 'import',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.restore_rounded),
                  title: Text('导入并安全合并'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: '重新读取记忆文件',
            icon: const Icon(Icons.refresh),
            onPressed: () => unawaited(_reloadMemory(context, ref)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editMemory(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加记忆'),
      ),
      body: SafeArea(
        child: asyncMemory.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _MemoryError(
            error: error,
            onRetry: () => ref.invalidate(memoryControllerProvider),
          ),
          data: (memory) => RefreshIndicator(
            onRefresh: () => _reloadMemory(context, ref),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                _StorageCard(memory: memory),
                const SizedBox(height: 18),
                Text(
                  '已保存 ${memory.entries.length} 条',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '常驻记忆会在每次对话中参与召回',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                if (memory.entries.isEmpty)
                  const _EmptyMemory()
                else
                  for (final entry in memory.entries)
                    _MemoryCard(
                      key: ValueKey(entry.id),
                      entry: entry,
                      onEdit: () => _editMemory(context, ref, entry: entry),
                      onTogglePinned: () => _run(
                        context,
                        () => ref
                            .read(memoryControllerProvider.notifier)
                            .togglePinned(entry),
                        success: entry.pinned ? '已改为按需召回' : '已设为常驻记忆',
                      ),
                      onDelete: () => _deleteMemory(context, ref, entry),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(memoryControllerProvider.notifier);
    final fileService = ref.read(memoryBackupFileServiceProvider);
    try {
      final markdown = await controller.exportMarkdown();
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final fileName =
          'expert-chat-memory-${now.year}${two(now.month)}${two(now.day)}-'
          '${two(now.hour)}${two(now.minute)}.md';
      final result = await fileService.exportMarkdown(
        markdown: markdown,
        fileName: fileName,
      );
      if (result == null || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('记忆备份已导出'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导出失败：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(memoryControllerProvider.notifier);
    final fileService = ref.read(memoryBackupFileServiceProvider);
    try {
      final markdown = await fileService.pickMarkdown();
      if (markdown == null) return;
      final plan = await controller.previewImport(markdown);
      if (!context.mounted) return;
      final selections =
          await showModalBottomSheet<List<MemoryImportSelection>>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => MemoryImportReviewSheet(plan: plan),
          );
      if (selections == null || selections.isEmpty || !context.mounted) return;
      final result = await controller.applyImport(selections);
      if (!context.mounted) return;
      final parts = <String>[
        if (result.added > 0) '新增 ${result.added} 条',
        if (result.replaced > 0) '更新 ${result.replaced} 条',
        if (result.skipped > 0) '跳过 ${result.skipped} 条',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(parts.isEmpty ? '没有需要合并的记忆' : parts.join('，')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('导入失败：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 重新读取记忆文件。失败时保留当前数据并提示,而不是抛未处理的异步异常。
  static Future<void> _reloadMemory(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(memoryControllerProvider.notifier).reload(refresh: true);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('重新读取失败：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static Future<void> _editMemory(
    BuildContext context,
    WidgetRef ref, {
    MemoryEntry? entry,
  }) async {
    final result = await showDialog<({String content, bool pinned})>(
      context: context,
      builder: (_) => _MemoryEditDialog(entry: entry),
    );
    if (result == null || !context.mounted) return;

    await _run(context, () async {
      final memoryController = ref.read(memoryControllerProvider.notifier);
      if (entry == null) {
        // 直接以目标 pinned 状态一次写入,避免先按常驻保存再改成按需的两次文件写。
        final saved = await ref
            .read(memoryRepositoryProvider)
            .add(content: result.content, pinned: result.pinned);
        if (!saved.created) {
          throw const MemoryValidationException('这条记忆已经存在。');
        }
        await memoryController.reload();
      } else {
        await memoryController.updateEntry(
          entry.id,
          content: result.content,
          pinned: result.pinned,
        );
      }
    }, success: entry == null ? '记忆已保存' : '记忆已更新');
  }

  static Future<void> _deleteMemory(
    BuildContext context,
    WidgetRef ref,
    MemoryEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('忘记这条内容？'),
        content: Text(entry.content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await _run(
      context,
      () => ref.read(memoryControllerProvider.notifier).delete(entry.id),
      success: '已忘记',
    );
  }

  static Future<void> _run(
    BuildContext context,
    Future<void> Function() operation, {
    required String success,
  }) async {
    try {
      await operation();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success), behavior: SnackBarBehavior.floating),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('操作失败：$error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// 添加/编辑记忆的对话框。控制器归对话框 State 所有,在路由退场动画
/// 完全结束后才随 State 一起释放,避免对话框动画中用到已 dispose 的控制器。
class _MemoryEditDialog extends StatefulWidget {
  const _MemoryEditDialog({this.entry});

  final MemoryEntry? entry;

  @override
  State<_MemoryEditDialog> createState() => _MemoryEditDialogState();
}

class _MemoryEditDialogState extends State<_MemoryEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.entry?.content ?? '');
  late bool _pinned = widget.entry?.pinned ?? true;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.entry == null ? '添加长期记忆' : '编辑长期记忆'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              maxLength: MemorySafety.maxContentChars,
              decoration: InputDecoration(
                labelText: '要记住的事实或偏好',
                hintText: '例如：回答默认使用中文，并优先给出可执行方案。',
                errorText: _error,
                alignLabelWithHint: true,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('常驻记忆'),
              subtitle: const Text('关闭后，仅在内容与当前问题匹配时召回。'),
              value: _pinned,
              onChanged: (value) => setState(() => _pinned = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            try {
              final content = MemorySafety.normalize(_controller.text);
              Navigator.of(context).pop((content: content, pinned: _pinned));
            } on MemoryValidationException catch (e) {
              setState(() => _error = e.message);
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.memory});

  final MemoryState memory;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_copy_outlined, color: scheme.primary),
                const SizedBox(width: 10),
                Text(
                  '本地 Markdown 记忆文件',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text('内容保存在应用沙盒，不会自动上传。发送消息时只读取最多 8 条相关记忆。'),
            if (memory.locationLabel.isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(
                memory.locationLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    super.key,
    required this.entry,
    required this.onEdit,
    required this.onTogglePinned,
    required this.onDelete,
  });

  final MemoryEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onTogglePinned;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.content, style: const TextStyle(height: 1.5)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      entry.pinned ? Icons.push_pin : Icons.manage_search,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      entry.pinned ? '常驻' : '按需',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
                Text(
                  _formatTime(entry.updatedAt),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                if (entry.sourceRole != null)
                  Text(
                    _sourceLabel(entry.sourceRole!),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: entry.pinned ? '改为按需召回' : '设为常驻记忆',
                  icon: Icon(
                    entry.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                  onPressed: onTogglePinned,
                ),
                IconButton(
                  tooltip: '编辑',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: onEdit,
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  static String _sourceLabel(String role) {
    if (role == 'user') return '来自用户消息';
    if (role.startsWith('user_candidate_')) return '来自用户确认';
    if (role == 'assistant') return '来自助手消息';
    return '来自备份或手动记录';
  }
}

class _EmptyMemory extends StatelessWidget {
  const _EmptyMemory();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 72),
    child: Column(
      children: [
        Icon(
          Icons.psychology_alt_outlined,
          size: 52,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 14),
        Text('还没有长期记忆', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        const Text('可以在这里添加，也可以在聊天消息下点击“记住”。'),
      ],
    ),
  );
}

class _MemoryError extends StatelessWidget {
  const _MemoryError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 42),
          const SizedBox(height: 12),
          Text('读取记忆失败：$error', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}
