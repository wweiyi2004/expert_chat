import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/study_models.dart';
import '../../domain/study/srs_scheduler.dart';
import '../../state/study_controller.dart';
import 'study_ui.dart';
import 'tutor_setup_page.dart';

class ReviewSessionPage extends ConsumerStatefulWidget {
  const ReviewSessionPage({super.key});

  @override
  ConsumerState<ReviewSessionPage> createState() => _ReviewSessionPageState();
}

class _ReviewSessionPageState extends ConsumerState<ReviewSessionPage> {
  var _revealed = false;
  var _index = 0;
  var _rating = false;
  List<StudyCard> _queue = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  void _reload() {
    final lib = ref.read(studyControllerProvider).value ?? StudyLibrary.empty;
    setState(() {
      _queue = const SrsScheduler().readyQueue(lib.cards);
      _index = 0;
      _revealed = false;
    });
  }

  Future<void> _rate(SrsRating rating) async {
    if (_rating || _index >= _queue.length) return;
    setState(() => _rating = true);
    final card = _queue[_index];
    try {
      await ref.read(studyControllerProvider.notifier).reviewCard(card, rating);
      if (!mounted) return;
      if (_index + 1 >= _queue.length) {
        _reload();
        return;
      }
      setState(() {
        _index += 1;
        _revealed = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存复习结果失败：$e')));
    } finally {
      if (mounted) setState(() => _rating = false);
    }
  }

  Future<void> _addToWrongBook(StudyCard card) async {
    try {
      await ref
          .read(studyControllerProvider.notifier)
          .addWrong(
            StudyWrongItem(
              quizSnapshot: StudyQuizItem(
                id: card.quizItemId,
                stem: card.front,
                type: StudyQuizType.short,
                answerText: card.back,
                explanation: card.hint,
                courseId: card.courseId,
                nodeId: card.nodeId,
              ),
              userAnswer: '复习时未记起',
            ),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入错题本')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加入错题本失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_queue.isEmpty) {
      return Scaffold(
        backgroundColor: studyPageBackground(context),
        appBar: AppBar(
          title: const Text('复习'),
          backgroundColor: Colors.transparent,
          scrolledUnderElevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('当前没有到期卡片。'),
                const SizedBox(height: 12),
                Text(
                  '可去导师 / 课程 / 刷题生成卡片，或在卡片库手动添加。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                OutlinedButton(onPressed: _reload, child: const Text('刷新')),
              ],
            ),
          ),
        ),
      );
    }

    final card = _queue[_index];
    return Scaffold(
      backgroundColor: studyPageBackground(context),
      appBar: AppBar(
        title: Text('复习 ${_index + 1}/${_queue.length}'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '正面',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: SingleChildScrollView(
                              child: Text(
                                card.front,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                          ),
                          if (_revealed) ...[
                            const Divider(),
                            Text(
                              '背面',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Text(
                                  card.back,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ),
                            if (card.hint.trim().isNotEmpty)
                              Text(
                                '提示：${card.hint}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (!_revealed)
                  FilledButton(
                    onPressed: () => setState(() => _revealed = true),
                    child: const Text('显示答案'),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      OutlinedButton(
                        onPressed: _rating
                            ? null
                            : () => _rate(SrsRating.again),
                        child: const Text('Again'),
                      ),
                      OutlinedButton(
                        onPressed: _rating ? null : () => _rate(SrsRating.hard),
                        child: const Text('Hard'),
                      ),
                      FilledButton(
                        onPressed: _rating ? null : () => _rate(SrsRating.good),
                        child: Text(_rating ? '保存中…' : 'Good'),
                      ),
                      FilledButton.tonal(
                        onPressed: _rating ? null : () => _rate(SrsRating.easy),
                        child: const Text('Easy'),
                      ),
                    ],
                  ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _rating ? null : () => _addToWrongBook(card),
                        child: const Text('加入错题本'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => TutorSetupPage(
                              initialTopic: card.front,
                              courseId: card.courseId,
                              nodeId: card.nodeId,
                            ),
                          ),
                        ),
                        child: const Text('请导师讲解'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
