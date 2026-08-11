import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/study_models.dart';
import '../../state/study_controller.dart';
import 'study_ui.dart';

class CardLibraryPage extends ConsumerWidget {
  const CardLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    final cards = lib.cards;

    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('卡片库'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: cards.isEmpty
          ? const Center(child: Text('暂无卡片。可在导师会话中生成，或手动添加。'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  itemCount: cards.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final c = cards[i];
                    return Card(
                      elevation: 0,
                      child: ListTile(
                        title: Text(
                          c.front,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '下次：${c.dueAt.toLocal().toString().substring(0, 16)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'edit') {
                              await _edit(context, ref, c);
                            } else if (v == 'delete') {
                              await ref
                                  .read(studyControllerProvider.notifier)
                                  .deleteCard(c.id);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    StudyCard? existing,
  ) async {
    final front = TextEditingController(text: existing?.front ?? '');
    final back = TextEditingController(text: existing?.back ?? '');
    final hint = TextEditingController(text: existing?.hint ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '新建卡片' : '编辑卡片'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: front,
              decoration: const InputDecoration(labelText: '正面'),
            ),
            TextField(
              controller: back,
              decoration: const InputDecoration(labelText: '背面'),
              maxLines: 3,
            ),
            TextField(
              controller: hint,
              decoration: const InputDecoration(labelText: '提示（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) {
      front.dispose();
      back.dispose();
      hint.dispose();
      return;
    }
    final card = existing == null
        ? StudyCard(
            front: front.text.trim(),
            back: back.text.trim(),
            hint: hint.text.trim(),
          )
        : existing.copyWith(
            front: front.text.trim(),
            back: back.text.trim(),
            hint: hint.text.trim(),
          );
    front.dispose();
    back.dispose();
    hint.dispose();
    if (card.front.isEmpty || card.back.isEmpty) return;
    await ref.read(studyControllerProvider.notifier).saveCard(card);
  }
}
