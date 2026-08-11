import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/study_models.dart';
import '../../state/study_controller.dart';
import 'quiz_player_page.dart';
import 'study_ui.dart';
import 'tutor_setup_page.dart';

class WrongBookPage extends ConsumerStatefulWidget {
  const WrongBookPage({super.key});

  @override
  ConsumerState<WrongBookPage> createState() => _WrongBookPageState();
}

class _WrongBookPageState extends ConsumerState<WrongBookPage> {
  static const _all = '__all__';
  static const _free = '__free__';
  var _filter = _all;

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    final nodeById = {for (final node in lib.nodes) node.id: node};
    final taggedNodeIds =
        lib.wrongItems
            .map((wrong) => wrong.quizSnapshot.nodeId)
            .whereType<String>()
            .toSet()
            .toList()
          ..sort(
            (a, b) =>
                (nodeById[a]?.title ?? a).compareTo(nodeById[b]?.title ?? b),
          );
    final hasFree = lib.wrongItems.any(
      (wrong) => wrong.quizSnapshot.nodeId == null,
    );
    final effectiveFilter =
        _filter == _all ||
            (_filter == _free && hasFree) ||
            taggedNodeIds.contains(_filter)
        ? _filter
        : _all;
    final filtered = lib.wrongItems.where((wrong) {
      if (effectiveFilter == _all) return true;
      if (effectiveFilter == _free) return wrong.quizSnapshot.nodeId == null;
      return wrong.quizSnapshot.nodeId == effectiveFilter;
    });
    final open = filtered
        .where((wrong) => wrong.status == StudyWrongStatus.open)
        .toList();
    final resolved = filtered
        .where((wrong) => wrong.status == StudyWrongStatus.resolved)
        .toList();

    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('错题本'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: lib.wrongItems.isEmpty
          ? const Center(child: Text('暂无错题。刷题答错后会自动收录。'))
          : StudyContent(
              maxWidth: 860,
              children: [
                const StudyPageLead(
                  icon: Icons.error_outline_rounded,
                  title: '把错过的题变成真正掌握',
                  subtitle: '重做、请导师讲解，或转成复习卡。答对后会自动移入已掌握。',
                ),
                if (taggedNodeIds.isNotEmpty || hasFree) ...[
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: effectiveFilter,
                    decoration: const InputDecoration(
                      labelText: '按知识点筛选',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(value: _all, child: Text('全部')),
                      if (hasFree)
                        const DropdownMenuItem(
                          value: _free,
                          child: Text('自由刷题'),
                        ),
                      for (final id in taggedNodeIds)
                        DropdownMenuItem(
                          value: id,
                          child: Text(nodeById[id]?.title ?? '已删除的知识点'),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _filter = value ?? _all;
                    }),
                  ),
                  const SizedBox(height: 16),
                ],
                if (open.isEmpty && resolved.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('该筛选条件下暂无错题')),
                  ),
                if (open.isNotEmpty) ...[
                  Text(
                    '待消化 (${open.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  for (final wrong in open) _WrongTile(item: wrong),
                ],
                if (resolved.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '已掌握 (${resolved.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  for (final wrong in resolved) _WrongTile(item: wrong),
                ],
              ],
            ),
    );
  }
}

class _WrongTile extends ConsumerWidget {
  const _WrongTile({required this.item});

  final StudyWrongItem item;

  Future<void> _makeCard(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(studyControllerProvider.notifier)
          .createCardFromWrong(item);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入复习卡库')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('生成卡片失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quiz = item.quizSnapshot;
    final library = ref.watch(studyControllerProvider).value;
    final node = library?.nodes
        .where((candidate) => candidate.id == quiz.nodeId)
        .firstOrNull;
    final course = library?.courses
        .where((candidate) => candidate.id == quiz.courseId)
        .firstOrNull;
    final tag = node?.title ?? course?.title;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tag != null) ...[
              Text(tag, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
            ],
            Text(
              quiz.stem,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '你的答案：${item.userAnswer}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '参考：${quiz.answerText.isNotEmpty ? quiz.answerText : quiz.answerKey}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '错过 ${item.missCount} 次',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (item.status == StudyWrongStatus.open)
                  FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => QuizPlayerPage(
                          topic: tag ?? '错题重做',
                          items: [quiz],
                          wrongItemId: item.id,
                        ),
                      ),
                    ),
                    child: const Text('重做'),
                  ),
                if (item.status == StudyWrongStatus.open)
                  TextButton(
                    onPressed: () => ref
                        .read(studyControllerProvider.notifier)
                        .resolveWrong(item.id),
                    child: const Text('已会'),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => TutorSetupPage(
                        initialTopic: quiz.stem,
                        courseId: quiz.courseId,
                        nodeId: quiz.nodeId,
                      ),
                    ),
                  ),
                  child: const Text('请导师讲'),
                ),
                TextButton(
                  onPressed: () => _makeCard(context, ref),
                  child: const Text('转复习卡'),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(studyControllerProvider.notifier)
                      .deleteWrong(item.id),
                  child: const Text('删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
