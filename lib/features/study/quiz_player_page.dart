import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/study_models.dart';
import '../../domain/study/quiz_codec.dart';
import '../../state/study_controller.dart';
import 'study_ui.dart';

class QuizPlayerPage extends ConsumerStatefulWidget {
  const QuizPlayerPage({
    super.key,
    required this.topic,
    required this.items,
    this.wrongItemId,
  });

  final String topic;
  final List<StudyQuizItem> items;
  final String? wrongItemId;

  @override
  ConsumerState<QuizPlayerPage> createState() => _QuizPlayerPageState();
}

class _QuizPlayerPageState extends ConsumerState<QuizPlayerPage> {
  var _index = 0;
  final _answers = <String, String>{};
  final _grades = <String, QuizGrade>{};
  var _busy = false;
  var _finished = false;
  var _resolvedWrong = false;

  StudyQuizItem get _item => widget.items[_index];

  Future<void> _submitCurrent() async {
    final ans = (_answers[_item.id] ?? '').trim();
    if (ans.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先作答')));
      return;
    }
    setState(() => _busy = true);
    try {
      final grade = await ref
          .read(studyControllerProvider.notifier)
          .gradeItem(_item, ans);
      _grades[_item.id] = grade;
      if (grade.correct && widget.wrongItemId != null && !_resolvedWrong) {
        await ref
            .read(studyControllerProvider.notifier)
            .resolveWrong(widget.wrongItemId!);
        _resolvedWrong = true;
      } else if (!grade.correct) {
        await ref
            .read(studyControllerProvider.notifier)
            .addWrong(StudyWrongItem(quizSnapshot: _item, userAnswer: ans));
      }
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('批改失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _next() {
    if (_index + 1 >= widget.items.length) {
      setState(() => _finished = true);
      return;
    }
    setState(() => _index += 1);
  }

  @override
  Widget build(BuildContext context) {
    if (_finished) {
      final correct = _grades.values.where((g) => g.correct).length;
      return Scaffold(
        backgroundColor: studyPageBackground(context),
        appBar: AppBar(
          title: const Text('本轮结果'),
          backgroundColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$correct / ${widget.items.length} 正确',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (_resolvedWrong) ...[
                const SizedBox(height: 8),
                const Text('该错题已自动标记为已掌握'),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      );
    }

    final grade = _grades[_item.id];
    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: Text('刷题 ${_index + 1}/${widget.items.length}'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: StudyContent(
        maxWidth: 760,
        children: [
          Text(widget.topic, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 12),
          Text(
            _item.stem,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          if (_item.options.isNotEmpty)
            ...List.generate(_item.options.length, (i) {
              final key = String.fromCharCode(65 + i);
              return RadioListTile<String>(
                value: key,
                // ignore: deprecated_member_use
                groupValue: _answers[_item.id],
                // ignore: deprecated_member_use
                onChanged: grade != null
                    ? null
                    : (v) => setState(() => _answers[_item.id] = v ?? key),
                title: Text('$key. ${_item.options[i]}'),
              );
            })
          else
            TextField(
              enabled: grade == null,
              onChanged: (v) => _answers[_item.id] = v,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入答案',
              ),
            ),
          if (grade != null) ...[
            const SizedBox(height: 12),
            Text(
              grade.correct
                  ? '✓ 正确'
                  : grade.partial
                  ? '△ 部分正确'
                  : '✗ 错误',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: grade.correct
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
            ),
            if (grade.explanation.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(grade.explanation),
            ],
            if (_item.explanation.trim().isNotEmpty &&
                _item.explanation != grade.explanation) ...[
              const SizedBox(height: 8),
              Text('解析：${_item.explanation}'),
            ],
          ],
          const SizedBox(height: 24),
          if (grade == null)
            FilledButton(
              onPressed: _busy ? null : _submitCurrent,
              child: Text(_busy ? '批改中…' : '提交'),
            )
          else
            FilledButton(
              onPressed: _next,
              child: Text(_index + 1 >= widget.items.length ? '查看结果' : '下一题'),
            ),
        ],
      ),
    );
  }
}
