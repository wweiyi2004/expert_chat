import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/state/learning_plan_controller.dart';
import 'package:expert_chat/state/study_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Tutor extends StudyController {
  final replies = <String>[];
  final requests = <String>[];
  @override
  Future<StudyLibrary> build() async => StudyLibrary.empty;
  @override
  Future<String> completeText({
    required String system,
    required String user,
    CancelToken? cancelToken,
  }) async {
    requests.add(user);
    return replies.removeAt(0);
  }
}

void main() {
  test(
    'daily learning persists real answers and reprioritizes review after restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final tutor = _Tutor();
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          studyControllerProvider.overrideWith(() => tutor),
        ],
      );
      addTearDown(container.dispose);
      tutor.replies.add(
        jsonEncode({
          'knowledge': [
            {
              'id': 'K1',
              'title': '基础',
              'criterion': '独立计算',
              'source': '用户讲义',
              'minutes': 20,
            },
            {
              'id': 'K2',
              'title': '应用',
              'criterion': '独立解释',
              'source': '待核对',
              'minutes': 20,
            },
          ],
          'schedule': '按日期进行复习与验收',
        }),
      );
      final ctrl = container.read(learningPlanControllerProvider.notifier);
      final id = await ctrl.create(
        topic: '数学',
        goal: '期末复习',
        deadline: '2026-12-01',
        dailyMinutes: 40,
        foundation: true,
        material: '来源：用户讲义',
      );
      expect(ctrl.plan(id).lessons, isEmpty);
      tutor.replies.add('## 概念\n例题 → 填步 → 变式 → 混合练习\n答案与解析');
      await ctrl.startToday(id, now: DateTime(2026, 10, 16));
      expect(ctrl.plan(id).evidence, isEmpty);
      final requestCount = tutor.requests.length;
      await ctrl.startToday(id, now: DateTime(2026, 10, 16));
      expect(
        tutor.requests.length,
        requestCount,
        reason: 'reopening today must not regenerate or bill again',
      );
      tutor.replies.add(
        jsonEncode({
          'assessment': 'K2 的计算有误，建议复做。',
          'passed': ['K1', 'unknown'],
          'needsReview': ['K2', 'unknown'],
        }),
      );
      await ctrl.submit(id, '2026-10-16', 'K1：2；K2：3');
      expect(ctrl.plan(id).evidence, {'K1': true, 'K2': false});
      expect(ctrl.plan(id).nextKnowledge().first.id, 'K2');
      final restored = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(restored.dispose);
      final saved = restored.read(learningPlanControllerProvider).single;
      expect(saved.lessons.single.feedback.single.answer, 'K1：2；K2：3');
      expect(saved.knowledge.first.source, '用户讲义');
      expect(container.read(learningBusyProvider), isEmpty);
    },
  );
  test('invalid model plan does not replace persisted plans', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tutor = _Tutor()..replies.add('{"knowledge":[],"schedule":""}');
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        studyControllerProvider.overrideWith(() => tutor),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      container
          .read(learningPlanControllerProvider.notifier)
          .create(
            topic: '数学',
            goal: '复习',
            deadline: '2026-12-01',
            dailyMinutes: 40,
            foundation: false,
            material: '',
          ),
      throwsA(isA<FormatException>()),
    );
    expect(prefs.containsKey(learningPlansKey), false);
    expect(container.read(learningBusyProvider), isEmpty);
  });
}
