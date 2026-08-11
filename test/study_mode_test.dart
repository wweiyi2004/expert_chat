import 'dart:convert';

import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/domain/study/course_tree.dart';
import 'package:expert_chat/domain/study/quiz_codec.dart';
import 'package:expert_chat/domain/study/srs_scheduler.dart';
import 'package:expert_chat/domain/study/study_prompt_assembler.dart';
import 'package:expert_chat/domain/study/tutor_style.dart';
import 'package:expert_chat/features/shell/shell_tab.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationMode.study', () {
    test('wire round-trip', () {
      expect(ConversationMode.fromWire('study'), ConversationMode.study);
      expect(ConversationMode.study.wire, 'study');
      expect(ConversationMode.fromWire('nope'), ConversationMode.chat);
    });
  });

  group('ShellTab.study', () {
    test('default visible includes study', () {
      expect(ShellTab.visible(researchModeEnabled: false), [
        ShellTab.chat,
        ShellTab.study,
        ShellTab.studio,
        ShellTab.settings,
      ]);
    });

    test('can hide study', () {
      expect(
        ShellTab.visible(
          researchModeEnabled: false,
          studyModeEnabled: false,
          creationModeEnabled: true,
        ),
        [ShellTab.chat, ShellTab.studio, ShellTab.settings],
      );
    });
  });

  group('SrsScheduler', () {
    const srs = SrsScheduler();

    test('again resets reps and schedules soon', () {
      final card = StudyCard(
        front: 'q',
        back: 'a',
        ease: 2.5,
        intervalDays: 10,
        repetitions: 3,
      );
      final now = DateTime(2026, 8, 10, 12);
      final next = srs.apply(card, SrsRating.again, now: now);
      expect(next.repetitions, 0);
      expect(next.intervalDays, 0);
      expect(next.ease, lessThan(2.5));
      expect(next.dueAt.isAfter(now), isTrue);
      expect(next.dueAt.difference(now).inMinutes, 10);
    });

    test('good first review -> 1 day', () {
      final card = StudyCard(front: 'q', back: 'a');
      final now = DateTime(2026, 8, 10);
      final next = srs.apply(card, SrsRating.good, now: now);
      expect(next.repetitions, 1);
      expect(next.intervalDays, 1);
      expect(next.dueAt, DateTime(2026, 8, 11));
    });

    test('due queue sorts and filters suspended', () {
      final day = DateTime(2026, 8, 10);
      final a = StudyCard(front: '1', back: 'a', dueAt: DateTime(2026, 8, 9));
      final b = StudyCard(
        front: '2',
        back: 'b',
        dueAt: DateTime(2026, 8, 10, 18),
      );
      final c = StudyCard(front: '3', back: 'c', dueAt: DateTime(2026, 8, 11));
      final d = StudyCard(
        front: '4',
        back: 'd',
        dueAt: DateTime(2026, 8, 8),
        suspended: true,
      );
      final q = srs.dueQueue([c, b, a, d], day: day);
      expect(q.map((e) => e.front).toList(), ['1', '2']);
    });

    test('ready queue honors the exact due time', () {
      final now = DateTime(2026, 8, 10, 12);
      final ready = StudyCard(
        front: 'ready',
        back: 'a',
        dueAt: now.subtract(const Duration(seconds: 1)),
      );
      final laterToday = StudyCard(
        front: 'later',
        back: 'b',
        dueAt: now.add(const Duration(minutes: 10)),
      );

      expect(
        srs.readyQueue([laterToday, ready], now: now).map((e) => e.front),
        ['ready'],
      );
      expect(srs.dueQueue([laterToday], day: now), [laterToday]);
    });
  });

  group('QuizCodec', () {
    const codec = QuizCodec();

    test('parses fenced json items', () {
      const raw = '''
```json
[
  {"type":"single","stem":"1+1?","options":["1","2"],"answer":"B","explanation":"ok"},
  {"type":"bool","stem":"地球是圆的","options":["正确","错误"],"answer":"正确"}
]
```
''';
      final items = codec.parseItems(raw);
      expect(items.length, 2);
      expect(items[0].type, StudyQuizType.single);
      expect(items[0].answerKey, 'B');
      expect(items[0].answerText, '2');
    });

    test('grades single choice locally', () {
      final item = StudyQuizItem(
        stem: 'q',
        type: StudyQuizType.single,
        options: const ['x', 'y'],
        answerKey: 'B',
        answerText: 'y',
      );
      expect(codec.gradeLocal(item, 'B')!.correct, isTrue);
      expect(codec.gradeLocal(item, 'A')!.correct, isFalse);
      expect(codec.gradeLocal(item, 'y')!.correct, isTrue);
    });

    test('normalizes JSON boolean answers to displayed options', () {
      final items = codec.parseItems(
        jsonEncode([
          {
            'type': 'bool',
            'stem': '地球是圆的',
            'options': ['正确', '错误'],
            'answer': true,
          },
          {
            'type': 'bool',
            'stem': '太阳从西边升起',
            'options': ['错误', '正确'],
            'correct': false,
          },
        ]),
      );

      expect(items[0].answerKey, 'A');
      expect(codec.gradeLocal(items[0], 'A')!.correct, isTrue);
      expect(codec.gradeLocal(items[0], 'B')!.correct, isFalse);
      expect(items[1].answerKey, 'A');
      expect(codec.gradeLocal(items[1], 'A')!.correct, isTrue);
    });

    test('grades legacy boolean items whose answer was stored as true', () {
      final item = StudyQuizItem(
        stem: '判断',
        type: StudyQuizType.boolType,
        options: const ['正确', '错误'],
        answerKey: 'true',
        answerText: 'true',
      );

      expect(codec.gradeLocal(item, 'A')!.correct, isTrue);
      expect(codec.gradeLocal(item, 'B')!.correct, isFalse);
    });

    test('parse cards', () {
      final cards = codec.parseCards(
        jsonEncode([
          {'front': 'Q1', 'back': 'A1'},
          {'front': '', 'back': 'skip'},
        ]),
      );
      expect(cards.length, 1);
      expect(cards.first.front, 'Q1');
    });

    test('clamps model-provided difficulty to the supported range', () {
      final items = codec.parseItems(
        jsonEncode([
          {'stem': 'hard', 'difficulty': 99},
          {'stem': 'easy', 'difficulty': -4},
        ]),
      );

      expect(items.map((item) => item.difficulty), [5, 1]);
    });
  });

  group('CourseTreeCodec', () {
    const tree = CourseTreeCodec();

    test('reopening a completed node preserves completion', () {
      final done = StudyNode(
        courseId: 'course',
        title: '已完成关卡',
        progress: StudyNodeProgress.done,
      );
      final available = StudyNode(
        courseId: 'course',
        title: '新关卡',
        progress: StudyNodeProgress.available,
      );

      expect(done.markStarted(), same(done));
      expect(available.markStarted().progress, StudyNodeProgress.inProgress);
    });

    test('parses nested outline and unlocks first leaf', () {
      final pack = tree.parse(
        raw: jsonEncode({
          'title': '课',
          'children': [
            {
              'title': '章1',
              'children': [
                {'title': '点A'},
                {'title': '点B'},
              ],
            },
          ],
        }),
        title: '课',
      );
      expect(pack, isNotNull);
      final leaves = pack!.nodes
          .where((n) => n.kind == StudyNodeKind.leaf)
          .toList();
      expect(leaves.length, 2);
      expect(leaves.first.progress, StudyNodeProgress.available);
      expect(leaves.last.progress, StudyNodeProgress.locked);
    });

    test('completeLeaf unlocks next', () {
      final pack = tree.fallback(title: 't');
      // expand with two leaves manually
      final c = pack.course;
      final a = StudyNode(
        courseId: c.id,
        title: 'A',
        kind: StudyNodeKind.leaf,
        orderIndex: 0,
        progress: StudyNodeProgress.available,
      );
      final b = StudyNode(
        courseId: c.id,
        title: 'B',
        kind: StudyNodeKind.leaf,
        orderIndex: 1,
        progress: StudyNodeProgress.locked,
      );
      final next = tree.completeLeaf([a, b], a.id);
      expect(
        next.firstWhere((n) => n.id == a.id).progress,
        StudyNodeProgress.done,
      );
      expect(
        next.firstWhere((n) => n.id == b.id).progress,
        StudyNodeProgress.available,
      );
    });

    test('leafOrder follows section depth-first order', () {
      final section = StudyNode(
        id: 'section',
        courseId: 'course',
        title: '第一章',
        kind: StudyNodeKind.section,
        orderIndex: 0,
      );
      final nested = StudyNode(
        id: 'nested',
        courseId: 'course',
        parentId: section.id,
        title: '章内知识点',
        orderIndex: 0,
      );
      final root = StudyNode(
        id: 'root',
        courseId: 'course',
        title: '根知识点',
        orderIndex: 1,
      );

      expect(tree.leafOrder([root, nested, section]).map((node) => node.id), [
        'nested',
        'root',
      ]);
    });
  });

  group('StudyPromptAssembler', () {
    test('session note encode/decode', () {
      final note = StudyPromptAssembler.encodeSessionNote(
        path: StudyPath.tutor,
        tutorStyle: TutorStyle.socratic,
        topic: '微积分',
      );
      final map = StudyPromptAssembler.decodeSessionNote(note);
      expect(map?['topic'], '微积分');
      expect(map?['tutorStyle'], 'socratic');
    });

    test('tutor system mentions style', () {
      final s = const StudyPromptAssembler().tutorSystem(
        style: TutorStyle.feynman,
        topic: '相对论',
      );
      expect(s.contains('费曼'), isTrue);
      expect(s.contains('相对论'), isTrue);
    });

    test('quiz prompt carries type and difficulty constraints', () {
      final prompt = const StudyPromptAssembler().quizGenerateUserPrompt(
        topic: '线性代数',
        count: 7,
        types: {StudyQuizType.single, StudyQuizType.cloze},
        difficulty: 4,
      );

      expect(prompt, contains('7'));
      expect(prompt, contains('single, cloze'));
      expect(prompt, isNot(contains('bool, short')));
      expect(prompt, contains('4/5'));
    });

    test('quiz difficulty is clamped to supported range', () {
      final prompt = const StudyPromptAssembler().quizGenerateUserPrompt(
        topic: '概率',
        difficulty: 9,
      );

      expect(prompt, contains('5/5'));
    });
  });
}
