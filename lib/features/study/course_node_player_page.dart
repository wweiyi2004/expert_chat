import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/study_models.dart';
import '../../state/study_controller.dart';
import 'study_generation_error.dart';
import 'study_ui.dart';
import 'tutor_setup_page.dart';

class CourseNodePlayerPage extends ConsumerStatefulWidget {
  const CourseNodePlayerPage({
    super.key,
    required this.courseId,
    required this.nodeId,
  });

  final String courseId;
  final String nodeId;

  @override
  ConsumerState<CourseNodePlayerPage> createState() =>
      _CourseNodePlayerPageState();
}

class _CourseNodePlayerPageState extends ConsumerState<CourseNodePlayerPage> {
  var _step = 0; // 0 explain, 1 check, 2 done
  String? _explain;
  var _loading = true;
  String? _error;
  List<StudyQuizItem> _items = const [];
  var _quizLoading = false;
  var _submitting = false;
  var _regenerating = false;
  var _makingCards = false;
  var _mastery = StudyMastery.familiar;
  final _answers = <String, String>{};
  final _grades = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadExplain());
  }

  Future<void> _loadExplain() async {
    final lib = ref.read(studyControllerProvider).value;
    final course = lib?.courses
        .where((c) => c.id == widget.courseId)
        .firstOrNull;
    final node = lib?.nodes.where((n) => n.id == widget.nodeId).firstOrNull;
    if (course == null || node == null) {
      setState(() {
        _loading = false;
        _error = '找不到课程节点';
      });
      return;
    }
    _mastery = node.mastery ?? StudyMastery.familiar;
    // Opening a completed lesson for reference must not roll its persisted
    // progress back to in-progress. Only a lesson that is starting for the
    // first time transitions here.
    final started = node.markStarted();
    if (!identical(started, node)) {
      await ref.read(studyControllerProvider.notifier).saveNode(started);
    }
    try {
      final text = await ref
          .read(studyControllerProvider.notifier)
          .ensureNodeExplain(course: course, node: node);
      if (!mounted) return;
      setState(() {
        _explain = text;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _regenerateExplain() async {
    if (_regenerating) return;
    final lib = ref.read(studyControllerProvider).value;
    final course = lib?.courses
        .where((course) => course.id == widget.courseId)
        .firstOrNull;
    final node = lib?.nodes
        .where((node) => node.id == widget.nodeId)
        .firstOrNull;
    if (course == null || node == null) return;
    setState(() => _regenerating = true);
    try {
      final text = await ref
          .read(studyControllerProvider.notifier)
          .ensureNodeExplain(course: course, node: node, regenerate: true);
      if (!mounted) return;
      setState(() => _explain = text);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('重新讲解失败：$error')));
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Future<void> _setMastery(StudyMastery mastery) async {
    final previous = _mastery;
    setState(() => _mastery = mastery);
    try {
      await ref
          .read(studyControllerProvider.notifier)
          .setNodeMastery(widget.nodeId, mastery);
    } catch (error) {
      if (!mounted) return;
      setState(() => _mastery = previous);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存掌握度失败：$error')));
    }
  }

  Future<void> _makeCards() async {
    if (_makingCards) return;
    final lib = ref.read(studyControllerProvider).value;
    final course = lib?.courses
        .where((course) => course.id == widget.courseId)
        .firstOrNull;
    final node = lib?.nodes
        .where((node) => node.id == widget.nodeId)
        .firstOrNull;
    if (course == null || node == null) return;
    setState(() => _makingCards = true);
    try {
      final controller = ref.read(studyControllerProvider.notifier);
      final cards = await controller.generateCards(
        topic: '${course.title} · ${node.title}',
        context: _explain ?? node.explainCache,
        count: 3,
        courseId: course.id,
        nodeId: node.id,
      );
      await controller.addCards(cards);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已生成 ${cards.length} 张复习卡')));
    } catch (error) {
      if (!mounted) return;
      await showStudyGenerationError(context, title: '复习卡生成失败', error: error);
    } finally {
      if (mounted) setState(() => _makingCards = false);
    }
  }

  Future<void> _startCheck() async {
    final lib = ref.read(studyControllerProvider).value;
    final course = lib?.courses
        .where((c) => c.id == widget.courseId)
        .firstOrNull;
    final node = lib?.nodes.where((n) => n.id == widget.nodeId).firstOrNull;
    if (course == null || node == null) return;
    setState(() {
      _quizLoading = true;
      _step = 1;
    });
    try {
      final items = await ref
          .read(studyControllerProvider.notifier)
          .generateQuiz(
            topic: course.title,
            focus: node.title,
            count: 3,
            courseId: course.id,
            nodeId: node.id,
          );
      if (!mounted) return;
      setState(() {
        _items = items;
        _quizLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _quizLoading = false;
        _error = '$e';
      });
      await showStudyGenerationError(context, title: '检查题生成失败', error: e);
    }
  }

  Future<void> _submitCheck() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final study = ref.read(studyControllerProvider.notifier);
    try {
      var allCorrect = _items.isNotEmpty;
      for (final item in _items) {
        final ans = (_answers[item.id] ?? '').trim();
        if (ans.isEmpty) {
          allCorrect = false;
          _grades[item.id] = '未作答';
          continue;
        }
        final grade = await study.gradeItem(item, ans);
        _grades[item.id] = grade.correct
            ? '正确'
            : (grade.partial ? '部分正确' : '错误');
        if (!grade.correct) {
          allCorrect = false;
          await study.addWrong(
            StudyWrongItem(quizSnapshot: item, userAnswer: ans),
          );
        }
      }
      if (!mounted) return;
      if (!allCorrect) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('尚未全部正确。可改答案后再次提交；错题已记入错题本。')),
        );
        return;
      }
      await study.completeNode(widget.nodeId);
      if (!mounted) return;
      setState(() => _step = 2);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('批改失败：$e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(studyControllerProvider).value;
    final node = lib?.nodes.where((n) => n.id == widget.nodeId).firstOrNull;
    final title = node?.title ?? '关卡';

    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            tooltip: '请导师讲',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TutorSetupPage(
                  initialTopic: title,
                  courseId: widget.courseId,
                  nodeId: widget.nodeId,
                ),
              ),
            ),
            icon: const Icon(Icons.psychology_alt_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _explain == null
          ? Center(child: Text(_error!))
          : StudyContent(
              maxWidth: 820,
              children: [
                if (_step == 0) ...[
                  Text(
                    '精讲',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(_explain ?? ''),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _regenerating ? null : _regenerateExplain,
                    icon: _regenerating
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_regenerating ? '重新生成中…' : '换一种讲法'),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _startCheck,
                    child: const Text('开始检查'),
                  ),
                ],
                if (_step == 1) ...[
                  Text(
                    '检查',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_quizLoading)
                    const Center(child: CircularProgressIndicator())
                  else if (_items.isEmpty)
                    const Text('未能生成题目，可返回重试或请导师讲解。')
                  else ...[
                    for (final item in _items) ...[
                      Text(
                        item.stem,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      if (item.options.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          children: [
                            for (var i = 0; i < item.options.length; i++)
                              ChoiceChip(
                                label: Text(
                                  '${String.fromCharCode(65 + i)}. ${item.options[i]}',
                                ),
                                selected:
                                    _answers[item.id] ==
                                    String.fromCharCode(65 + i),
                                onSelected: _submitting
                                    ? null
                                    : (_) => setState(() {
                                        _answers[item.id] = String.fromCharCode(
                                          65 + i,
                                        );
                                      }),
                              ),
                          ],
                        )
                      else
                        TextField(
                          enabled: !_submitting,
                          onChanged: (v) => _answers[item.id] = v,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: '你的答案',
                          ),
                        ),
                      if (_grades[item.id] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(_grades[item.id]!),
                        ),
                      const SizedBox(height: 16),
                    ],
                    FilledButton(
                      onPressed: _submitting ? null : _submitCheck,
                      child: Text(
                        _submitting
                            ? '批改中…'
                            : (_grades.isEmpty ? '提交检查' : '再次提交'),
                      ),
                    ),
                  ],
                ],
                if (_step == 2) ...[
                  const Icon(Icons.celebration_outlined, size: 48),
                  const SizedBox(height: 12),
                  const Text('本关完成。下一叶子知识点已解锁（若有）。'),
                  const SizedBox(height: 16),
                  Text('掌握度', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mastery in StudyMastery.values)
                        ChoiceChip(
                          label: Text(mastery.label),
                          selected: _mastery == mastery,
                          onSelected: (selected) {
                            if (selected) _setMastery(mastery);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _makingCards ? null : _makeCards,
                    icon: _makingCards
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.style_outlined),
                    label: Text(_makingCards ? '生成中…' : '生成 3 张复习卡'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回课程'),
                  ),
                ],
              ],
            ),
    );
  }
}

extension _FirstOrNull2<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}
