import 'dart:convert';
import 'package:expert_chat/data/learning_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const knowledge = [
    LearningKnowledge(
      id: 'K1',
      title: 'first',
      criterion: 'explain',
      source: 'user notes',
      minutes: 20,
    ),
    LearningKnowledge(
      id: 'K2',
      title: 'second',
      criterion: 'solve',
      source: 'user notes',
      minutes: 30,
    ),
    LearningKnowledge(
      id: 'K3',
      title: 'third',
      criterion: 'derive',
      source: 'unverified',
      minutes: 20,
    ),
  ];
  const plan = LearningPlan(
    id: 'p',
    topic: 'math',
    goal: 'exam',
    deadline: '2026-12-01',
    dailyMinutes: 40,
    foundation: true,
    material: 'notes',
    knowledge: knowledge,
    schedule: 'schedule',
  );
  test('generating a lesson cannot manufacture evidence or mastery', () {
    final p = plan.withLessons([
      const LearningLesson(
        date: '2026-10-16',
        knowledgeIds: ['K1'],
        content: 'example',
      ),
    ]);
    expect(p.evidence, isEmpty);
    expect(p.nextKnowledge().map((k) => k.id), ['K1']);
  });
  test('real feedback reprioritizes review and respects available time', () {
    final p = plan.withLessons([
      const LearningLesson(
        date: '2026-10-16',
        knowledgeIds: ['K1', 'K2'],
        content: 'lesson',
        feedback: [
          LearningFeedback(
            answer: 'my answers',
            assessment: 'mistake in K2',
            date: '2026-10-16',
            passed: ['K1'],
            needsReview: ['K2'],
          ),
        ],
      ),
    ]);
    expect(p.nextKnowledge().map((k) => k.id), ['K2']);
    final restored = LearningPlan.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
    expect(restored.lessons.single.feedback.single.answer, 'my answers');
    expect(restored.evidence, {'K1': true, 'K2': false});
  });
  test(
    'later practice evidence can correct a previously failed knowledge point',
    () {
      final p = plan.withLessons([
        const LearningLesson(
          date: '2026-10-16',
          knowledgeIds: ['K1'],
          content: 'lesson',
          feedback: [
            LearningFeedback(
              answer: 'wrong',
              assessment: 'incorrect',
              date: '2026-10-16',
              needsReview: ['K1'],
            ),
            LearningFeedback(
              answer: 'corrected',
              assessment: 'correct',
              date: '2026-10-17',
              passed: ['K1'],
            ),
          ],
        ),
      ]);
      expect(p.evidence['K1'], true);
      expect(p.nextKnowledge().first.id, 'K2');
    },
  );
}
