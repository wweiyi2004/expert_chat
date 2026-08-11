import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/mode_style.dart';
import '../../data/study_models.dart';
import '../../state/study_controller.dart';
import 'quiz_player_page.dart';
import 'study_generation_error.dart';
import 'study_ui.dart';

class QuizSetupPage extends ConsumerStatefulWidget {
  const QuizSetupPage({
    super.key,
    this.initialTopic = '',
    this.initialCount = 5,
    this.initialCourseId,
    this.initialNodeId,
  });

  final String initialTopic;
  final int initialCount;
  final String? initialCourseId;
  final String? initialNodeId;

  @override
  ConsumerState<QuizSetupPage> createState() => _QuizSetupPageState();
}

class _QuizSetupPageState extends ConsumerState<QuizSetupPage> {
  late final TextEditingController _topic;
  late int _count;
  final _types = StudyQuizType.values.toSet();
  var _difficulty = 3;
  var _loading = false;
  String? _courseId;
  String? _nodeId;

  @override
  void initState() {
    super.initState();
    _topic = TextEditingController(text: widget.initialTopic);
    _count = widget.initialCount.clamp(3, 15);
    _courseId = widget.initialCourseId;
    _nodeId = widget.initialNodeId;
  }

  @override
  void dispose() {
    _topic.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final library = ref.read(studyControllerProvider).value;
    final selectedCourse = library?.courses
        .where((course) => course.id == _courseId)
        .firstOrNull;
    final selectedNode = library?.nodes
        .where(
          (node) => node.id == _nodeId && node.courseId == selectedCourse?.id,
        )
        .firstOrNull;
    final topic = _topic.text.trim().isNotEmpty
        ? _topic.text.trim()
        : selectedCourse?.title ?? '';
    if (topic.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写主题')));
      return;
    }
    setState(() => _loading = true);
    try {
      final items = await ref
          .read(studyControllerProvider.notifier)
          .generateQuiz(
            topic: topic,
            count: _count,
            types: _types,
            difficulty: _difficulty,
            focus: selectedNode?.title ?? '',
            courseId: selectedCourse?.id,
            nodeId: selectedNode?.id,
          );
      if (!mounted) return;
      if (items.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能解析题目，请重试或换模型')));
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => QuizPlayerPage(topic: topic, items: items),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      await showStudyGenerationError(context, title: '出题失败', error: e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library =
        ref.watch(studyControllerProvider).value ?? StudyLibrary.empty;
    final selectedCourse = library.courses
        .where((course) => course.id == _courseId)
        .firstOrNull;
    final courseNodes = selectedCourse == null
        ? <StudyNode>[]
        : library.nodes
              .where(
                (node) =>
                    node.courseId == selectedCourse.id &&
                    node.kind == StudyNodeKind.leaf,
              )
              .toList();
    courseNodes.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: const Text('刷题'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: StudyContent(
        maxWidth: 820,
        children: [
          const StudyPageLead(
            icon: Icons.task_alt_outlined,
            title: '生成一组刚刚好的练习',
            subtitle: '先确定范围，再调整题型和难度。完成后会立即批改，答错的题目自动进入错题本。',
          ),
          StudyPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StudySectionTitle(
                  title: '练习范围',
                  subtitle: '可以用自由主题，也可以绑定已有课程或知识点',
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _topic,
                  decoration: InputDecoration(
                    labelText: '主题',
                    hintText: '例如：牛顿第二定律',
                    filled: true,
                    fillColor: scheme.surface,
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (library.courses.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: selectedCourse?.id ?? '__free__',
                    decoration: InputDecoration(
                      labelText: '出题来源',
                      filled: true,
                      fillColor: scheme.surface,
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: '__free__',
                        child: Text('自由主题'),
                      ),
                      for (final course in library.courses)
                        DropdownMenuItem(
                          value: course.id,
                          child: Text(course.title),
                        ),
                    ],
                    onChanged: _loading
                        ? null
                        : (value) => setState(() {
                            _courseId = value == '__free__' ? null : value;
                            _nodeId = null;
                            final course = library.courses
                                .where((candidate) => candidate.id == _courseId)
                                .firstOrNull;
                            if (course != null && _topic.text.trim().isEmpty) {
                              _topic.text = course.title;
                            }
                          }),
                  ),
                  if (selectedCourse != null && courseNodes.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: courseNodes.any((node) => node.id == _nodeId)
                          ? _nodeId
                          : '__all__',
                      decoration: InputDecoration(
                        labelText: '知识点',
                        filled: true,
                        fillColor: scheme.surface,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '__all__',
                          child: Text('整门课程'),
                        ),
                        for (final node in courseNodes)
                          DropdownMenuItem(
                            value: node.id,
                            child: Text(node.title),
                          ),
                      ],
                      onChanged: _loading
                          ? null
                          : (value) => setState(() {
                              _nodeId = value == '__all__' ? null : value;
                            }),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          StudyPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StudySectionTitle(
                  title: '练习设置',
                  subtitle: '默认配置适合一次 5–10 分钟的快速自测',
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final countSlider = _QuizSlider(
                      label: '题量',
                      valueLabel: '$_count 道',
                      value: _count.toDouble(),
                      min: 3,
                      max: 15,
                      divisions: 12,
                      startLabel: '3',
                      endLabel: '15',
                      onChanged: _loading
                          ? null
                          : (value) => setState(() => _count = value.round()),
                    );
                    final difficultySlider = _QuizSlider(
                      label: '难度',
                      valueLabel: _difficultyLabel(_difficulty),
                      value: _difficulty.toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      startLabel: '入门',
                      endLabel: '挑战',
                      onChanged: _loading
                          ? null
                          : (value) =>
                                setState(() => _difficulty = value.round()),
                    );
                    if (constraints.maxWidth < 600) {
                      return Column(
                        children: [
                          countSlider,
                          const SizedBox(height: 18),
                          difficultySlider,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: countSlider),
                        const SizedBox(width: 28),
                        Expanded(child: difficultySlider),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                Text(
                  '题型',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 8,
                  runSpacing: 7,
                  children: [
                    for (final type in StudyQuizType.values)
                      FilterChip(
                        label: Text(_typeLabel(type)),
                        selected: _types.contains(type),
                        selectedColor: ModeStyle.study.withValues(alpha: 0.11),
                        checkmarkColor: ModeStyle.study,
                        side: BorderSide(
                          color: _types.contains(type)
                              ? ModeStyle.study.withValues(alpha: 0.35)
                              : scheme.outlineVariant,
                        ),
                        onSelected: _loading
                            ? null
                            : (selected) {
                                if (!selected && _types.length == 1) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('至少保留一种题型')),
                                  );
                                  return;
                                }
                                setState(() {
                                  if (selected) {
                                    _types.add(type);
                                  } else {
                                    _types.remove(type);
                                  }
                                });
                              },
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _loading ? null : _go,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward_rounded),
              label: Text(_loading ? '正在出题…' : '生成练习'),
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(StudyQuizType type) => switch (type) {
    StudyQuizType.single => '单选',
    StudyQuizType.boolType => '判断',
    StudyQuizType.cloze => '填空',
    StudyQuizType.short => '简答',
  };

  String _difficultyLabel(int difficulty) => switch (difficulty) {
    1 => '入门',
    2 => '较易',
    3 => '标准',
    4 => '较难',
    _ => '挑战',
  };
}

class _QuizSlider extends StatelessWidget {
  const _QuizSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.startLabel,
    required this.endLabel,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String startLabel;
  final String endLabel;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: ModeStyle.study.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                valueLabel,
                style: const TextStyle(
                  color: ModeStyle.study,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
        Row(
          children: [
            Text(startLabel, style: theme.textTheme.labelSmall),
            const Spacer(),
            Text(endLabel, style: theme.textTheme.labelSmall),
          ],
        ),
      ],
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
