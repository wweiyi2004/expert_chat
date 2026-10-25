import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../state/work_memory.dart';

class WorkMemoryCard extends ConsumerStatefulWidget {
  const WorkMemoryCard({
    super.key,
    required this.conversationId,
    this.initiallyExpanded = false,
  });
  final String conversationId;
  final bool initiallyExpanded;
  @override
  ConsumerState<WorkMemoryCard> createState() => _WorkMemoryCardState();
}

class _WorkMemoryCardState extends ConsumerState<WorkMemoryCard> {
  String? error;
  bool saving = false;
  Future<void> edit() async {
    if (saving) return;
    setState(() => saving = true);
    await showDialog<bool>(
      context: context,
      builder: (context) =>
          WorkMemoryEditDialog(conversationId: widget.conversationId),
    );
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final memory = ref.read(workMemoryProvider).snapshot(widget.conversationId);
    return ExpansionTile(
      initiallyExpanded: widget.initiallyExpanded,
      title: Text(
        ref.read(workMemoryProvider).corrupt
            ? '任务记忆损坏 · 需核验修复'
            : '任务记忆与计划 · v${memory['revision'] ?? 0}',
      ),
      subtitle: const Text('公开笔记；固定约束由你编辑，下一工具轮生效'),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  TextButton.icon(
                    onPressed: saving ? null : edit,
                    icon: const Icon(Icons.push_pin_outlined),
                    label: const Text('编辑固定约束'),
                  ),
                  for (final item in [
                    ('user_pins', '你的固定约束'),
                    ('constraints', '模型整理约束'),
                    ('plan', '公开计划'),
                    ('summary', '压缩摘要'),
                  ])
                    if ((memory[item.$1] as String? ?? '').isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SelectableText('${item.$2}\n${memory[item.$1]}'),
                      ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class WorkMemoryEditDialog extends ConsumerStatefulWidget {
  const WorkMemoryEditDialog({super.key, required this.conversationId});
  final String conversationId;
  @override
  ConsumerState<WorkMemoryEditDialog> createState() =>
      _WorkMemoryEditDialogState();
}

class _WorkMemoryEditDialogState extends ConsumerState<WorkMemoryEditDialog> {
  late final TextEditingController editor;
  int revision = 0;
  bool saving = false;
  String? error;
  String? latestPins;
  bool repairAcknowledged = false;
  String? reviewedCorruptDigest, reviewedCorruptSource;
  @override
  void initState() {
    super.initState();
    final store = ref.read(workMemoryProvider);
    reviewedCorruptDigest = store.corruptDigest;
    reviewedCorruptSource = store.corruptSource;
    final memory = store.snapshot(widget.conversationId);
    revision = (memory['revision'] as num?)?.toInt() ?? 0;
    editor = TextEditingController(text: memory['user_pins'] as String? ?? '');
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      final store = ref.read(workMemoryProvider);
      if (store.corrupt) {
        if (!repairAcknowledged) throw StateError('请先明确核验全局损坏范围');
        await store.repairCorrupt(
          widget.conversationId,
          reviewedCorruptDigest ?? '',
          editor.text,
        );
      } else {
        await store.checkpoint(widget.conversationId, {
          'expected_revision': revision,
          'user_pins': editor.text,
        }, userInitiated: true);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('固定任务约束 · v$revision'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ref.read(workMemoryProvider).corrupt) ...[
              const Text(
                '全局工作记忆损坏，其他会话的约束也无法确认。重建前须核验所有必要约束；原始损坏记录会先另存，当前输入作为新固定约束保存。',
              ),
              SelectableText('来源 SHA-256：$reviewedCorruptDigest'),
              TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: reviewedCorruptSource ?? ''),
                ),
                child: const Text('复制原始损坏记录'),
              ),
              CheckboxListTile(
                value: repairAcknowledged,
                onChanged: saving
                    ? null
                    : (value) =>
                          setState(() => repairAcknowledged = value == true),
                title: const Text('已核验全局影响；同意保留损坏副本并重建'),
              ),
            ],
            TextField(
              controller: editor,
              minLines: 5,
              maxLines: 10,
              maxLength: 12000,
              decoration: const InputDecoration(
                hintText: '仅你可修改；模型更新不会覆盖这些约束。',
              ),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (error != null)
              TextButton(
                onPressed: saving
                    ? null
                    : () {
                        final memory = ref
                            .read(workMemoryProvider)
                            .snapshot(widget.conversationId);
                        setState(() {
                          revision = (memory['revision'] as num?)?.toInt() ?? 0;
                          latestPins = memory['user_pins'] as String? ?? '';
                          error = null;
                        });
                      },
                child: const Text('刷新基线（保留草稿）'),
              ),
            if (latestPins != null) SelectableText('当前已保存约束：$latestPins'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving ? null : save,
        child: Text(saving ? '保存中…' : '保存'),
      ),
    ],
  );
}
