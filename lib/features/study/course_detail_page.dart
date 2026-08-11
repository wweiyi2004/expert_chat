import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../data/study_models.dart';
import '../../state/study_controller.dart';
import 'course_node_player_page.dart';
import 'study_ui.dart';
import 'tutor_setup_page.dart';

class CourseDetailPage extends ConsumerWidget {
  const CourseDetailPage({super.key, required this.courseId});

  final String courseId;

  Future<String?> _askTitle(
    BuildContext context, {
    required String title,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.trim().isEmpty ? null : result.trim();
  }

  Future<void> _addNode(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
  }) async {
    var kind = StudyNodeKind.leaf;
    if (parentId == null) {
      final selected = await showDialog<StudyNodeKind>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('添加课程节点'),
          children: [
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(dialogContext, StudyNodeKind.section),
              child: const ListTile(
                leading: Icon(Icons.folder_outlined),
                title: Text('章节'),
                subtitle: Text('可在其下继续添加知识点'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, StudyNodeKind.leaf),
              child: const ListTile(
                leading: Icon(Icons.school_outlined),
                title: Text('知识点'),
                subtitle: Text('可直接学习和过关'),
              ),
            ),
          ],
        ),
      );
      if (selected == null || !context.mounted) return;
      kind = selected;
    }
    final title = await _askTitle(
      context,
      title: kind == StudyNodeKind.section ? '新章节' : '新知识点',
    );
    if (title == null || !context.mounted) return;
    try {
      await ref
          .read(studyControllerProvider.notifier)
          .addNode(
            courseId: courseId,
            title: title,
            parentId: parentId,
            kind: kind,
          );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('添加失败：$error')));
    }
  }

  Future<void> _renameNode(
    BuildContext context,
    WidgetRef ref,
    StudyNode node,
  ) async {
    final title = await _askTitle(
      context,
      title: '重命名节点',
      initialValue: node.title,
    );
    if (title == null || !context.mounted) return;
    await ref.read(studyControllerProvider.notifier).renameNode(node.id, title);
  }

  Future<void> _deleteNode(
    BuildContext context,
    WidgetRef ref,
    StudyNode node,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除节点？'),
        content: Text(
          node.kind == StudyNodeKind.section
              ? '「${node.title}」及其下所有知识点都会被删除。'
              : '「${node.title}」将被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(studyControllerProvider.notifier).deleteNode(node.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    final course = lib.courses.where((c) => c.id == courseId).firstOrNull;
    if (course == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('课程')),
        body: const Center(child: Text('课程不存在或已删除')),
      );
    }
    final rows = _orderedNodes(
      lib.nodes.where((node) => node.courseId == courseId).toList(),
    );
    final leaves = rows
        .map((row) => row.node)
        .where((node) => node.kind == StudyNodeKind.leaf)
        .toList();
    final done = leaves
        .where((node) => node.progress == StudyNodeProgress.done)
        .length;
    final ratio = leaves.isEmpty ? 0.0 : done / leaves.length;

    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('课程详情'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            tooltip: '添加节点',
            onPressed: () => _addNode(context, ref),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: '用导师学本课',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TutorSetupPage(
                  initialTopic: course.title,
                  courseId: course.id,
                ),
              ),
            ),
            icon: const Icon(Icons.psychology_alt_outlined),
          ),
        ],
      ),
      body: StudyContent(
        maxWidth: 860,
        children: [
          StudyPageLead(
            icon: Icons.route_outlined,
            title: course.title,
            subtitle: course.sourceSummary.trim().isEmpty
                ? '按知识路径逐一完成，每个知识点都包含精讲和检查。'
                : _materialPreview(course.sourceSummary),
          ),
          StudyPanel(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '课程进度',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 7,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Text(
                  '$done / ${leaves.length}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: ModeStyle.study,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const StudySectionTitle(title: '学习路径', subtitle: '完成当前知识点后，下一节会自动解锁'),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            StudyPanel(
              child: Center(
                child: Column(
                  children: [
                    const Text('课程暂无节点'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _addNode(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('添加节点'),
                    ),
                  ],
                ),
              ),
            ),
          for (var i = 0; i < rows.length; i++) ...[
            Padding(
              padding: EdgeInsets.only(left: rows[i].depth * 18.0),
              child: Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                  side: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.58),
                  ),
                ),
                child: ListTile(
                  leading: Icon(
                    _iconFor(rows[i].node),
                    color: rows[i].node.progress == StudyNodeProgress.locked
                        ? Theme.of(context).colorScheme.outline
                        : ModeStyle.study,
                  ),
                  title: Text(
                    rows[i].node.title,
                    style: TextStyle(
                      fontWeight: rows[i].node.kind == StudyNodeKind.section
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  subtitle: rows[i].node.kind == StudyNodeKind.leaf
                      ? Text(_progressLabel(rows[i].node))
                      : const Text('章节'),
                  trailing: PopupMenuButton<String>(
                    tooltip: '节点操作',
                    onSelected: (action) {
                      if (action == 'add') {
                        _addNode(context, ref, parentId: rows[i].node.id);
                      } else if (action == 'rename') {
                        _renameNode(context, ref, rows[i].node);
                      } else if (action == 'delete') {
                        _deleteNode(context, ref, rows[i].node);
                      }
                    },
                    itemBuilder: (_) => [
                      if (rows[i].node.kind == StudyNodeKind.section)
                        const PopupMenuItem(value: 'add', child: Text('添加知识点')),
                      const PopupMenuItem(value: 'rename', child: Text('重命名')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  enabled:
                      rows[i].node.kind == StudyNodeKind.section ||
                      rows[i].node.progress != StudyNodeProgress.locked,
                  onTap:
                      rows[i].node.kind != StudyNodeKind.leaf ||
                          rows[i].node.progress == StudyNodeProgress.locked
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CourseNodePlayerPage(
                              courseId: course.id,
                              nodeId: rows[i].node.id,
                            ),
                          ),
                        ),
                ),
              ),
            ),
            if (i != rows.length - 1) const SizedBox(height: 7),
          ],
        ],
      ),
    );
  }

  String _materialPreview(String material) {
    final trimmed = material.trim();
    final firstLine = trimmed.split('\n').first.trim();
    if (firstLine.startsWith('[资料：') && firstLine.endsWith(']')) {
      return '已导入${firstLine.substring(1, firstLine.length - 1)}';
    }
    return trimmed;
  }

  IconData _iconFor(StudyNode node) {
    if (node.kind == StudyNodeKind.section) return Icons.folder_outlined;
    return switch (node.progress) {
      StudyNodeProgress.done => Icons.check_circle,
      StudyNodeProgress.inProgress => Icons.timelapse,
      StudyNodeProgress.available => Icons.radio_button_unchecked,
      StudyNodeProgress.locked => Icons.lock_outline,
    };
  }

  String _progressLabel(StudyNode node) {
    final progress = switch (node.progress) {
      StudyNodeProgress.done => '已完成',
      StudyNodeProgress.inProgress => '进行中',
      StudyNodeProgress.available => '可学习',
      StudyNodeProgress.locked => '未解锁',
    };
    final mastery = node.mastery?.label;
    return mastery == null ? progress : '$progress · $mastery';
  }
}

List<({StudyNode node, int depth})> _orderedNodes(List<StudyNode> nodes) {
  final byParent = <String?, List<StudyNode>>{};
  for (final node in nodes) {
    byParent.putIfAbsent(node.parentId, () => []).add(node);
  }
  for (final siblings in byParent.values) {
    siblings.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  }
  final result = <({StudyNode node, int depth})>[];
  final visited = <String>{};
  void walk(String? parentId, int depth) {
    for (final node in byParent[parentId] ?? const <StudyNode>[]) {
      if (!visited.add(node.id)) continue;
      result.add((node: node, depth: depth));
      walk(node.id, depth + 1);
    }
  }

  walk(null, 0);
  // Keep malformed/orphaned legacy nodes visible and editable instead of
  // silently losing them from the course screen.
  for (final node in nodes) {
    if (visited.add(node.id)) result.add((node: node, depth: 0));
  }
  return result;
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) return null;
    return iterator.current;
  }
}
