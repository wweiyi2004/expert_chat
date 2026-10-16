import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/data/study_repository.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/study/structured_output.dart';
import 'package:expert_chat/features/study/quiz_player_page.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/study_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadySettings extends SettingsController {
  _ReadySettings({this.apiKey = 'sk-test'});
  final String apiKey;
  @override
  Future<SettingsState> build() async {
    final profile = ProviderProfile(
      name: '测试',
      baseUrl: 'https://example.com/v1',
      chatModel: 'test-model',
      reasonerModel: 'test-model',
      models: const ['test-model'],
    );
    return SettingsState(
      profiles: [profile],
      activeProfileId: profile.id,
      apiKey: apiKey,
    );
  }
}

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.responses);

  final List<Object> responses;
  final List<List<LlmRequestMessage>> calls = [];

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    ReasoningEffort? reasoningEffort,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls.add(List.of(messages));
    final index = (calls.length - 1).clamp(0, responses.length - 1);
    final response = responses[index];
    if (response is! String) throw response;
    yield ChatChunk(contentDelta: response);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late StudyRepository repository;
  late ProviderContainer container;

  Future<void> prepare({LlmProvider? llm, String apiKey = 'sk-test'}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase(NativeDatabase.memory());
    repository = StudyRepository(db, prefs);
    container = ProviderContainer(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repository),
        settingsControllerProvider.overrideWith(
          () => _ReadySettings(apiKey: apiKey),
        ),
        if (llm != null) llmProvider.overrideWithValue(llm),
      ],
    );
    await container.read(settingsControllerProvider.future);
    await container.read(studyControllerProvider.future);
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'structured quiz output retries once and keeps requested types',
    () async {
      final llm = _ScriptedLlm([
        '这不是 JSON',
        '[{"type":"cloze","stem":"2+2=?","answer":"4",'
            '"explanation":"","difficulty":4}]',
      ]);
      await prepare(llm: llm);

      final items = await container
          .read(studyControllerProvider.notifier)
          .generateQuiz(
            topic: '数学',
            count: 3,
            types: {StudyQuizType.cloze},
            difficulty: 4,
          );

      expect(items, hasLength(1));
      expect(items.single.type, StudyQuizType.cloze);
      expect(llm.calls, hasLength(2));
      expect(llm.calls.last.first.content, contains('上次输出无法解析'));
      expect(llm.calls.first.last.content, contains('只使用题型：cloze'));
      expect(llm.calls.first.last.content, contains('目标难度：4/5'));
    },
  );

  test('structured failure exposes the second raw output', () async {
    final llm = _ScriptedLlm(['bad-1', 'bad-2']);
    await prepare(llm: llm);

    await expectLater(
      container
          .read(studyControllerProvider.notifier)
          .generateCards(topic: '数学', context: '内容'),
      throwsA(
        isA<StudyStructuredOutputException>().having(
          (error) => error.rawOutput,
          'rawOutput',
          'bad-2',
        ),
      ),
    );
    expect(llm.calls, hasLength(2));
  });

  test(
    'short-answer grading propagates unusable output without assigning a grade',
    () async {
      final llm = _ScriptedLlm(['not-json', '原始批改意见']);
      await prepare(llm: llm);
      final item = StudyQuizItem(
        stem: '解释惯性',
        type: StudyQuizType.short,
        answerText: '物体保持运动状态的性质',
      );

      await expectLater(
        container
            .read(studyControllerProvider.notifier)
            .gradeItem(item, '不完整回答'),
        throwsA(
          isA<StudyStructuredOutputException>().having(
            (error) => error.rawOutput,
            'rawOutput',
            '原始批改意见',
          ),
        ),
      );

      expect(llm.calls, hasLength(2));
      expect((await repository.load()).wrongItems, isEmpty);
    },
  );

  test('missing API key does not create a placeholder course', () async {
    final llm = _ScriptedLlm(['unused']);
    await prepare(llm: llm, apiKey: '');
    await expectLater(
      container
          .read(studyControllerProvider.notifier)
          .createCourseFromTopic('数学'),
      throwsStateError,
    );
    expect(llm.calls, isEmpty);
    expect((await repository.load()).courses, isEmpty);
    expect((await repository.load()).nodes, isEmpty);
  });

  test('request failure does not create a placeholder course', () async {
    final failure = StateError('request failed');
    await prepare(llm: _ScriptedLlm([failure]));
    await expectLater(
      container
          .read(studyControllerProvider.notifier)
          .createCourseFromTopic('数学'),
      throwsA(same(failure)),
    );
    expect((await repository.load()).courses, isEmpty);
    expect((await repository.load()).nodes, isEmpty);
  });

  for (final output in ['not-json', '[]', '{}']) {
    test(
      'unusable outline does not create a placeholder course: $output',
      () async {
        final llm = _ScriptedLlm([output]);
        await prepare(llm: llm);
        await expectLater(
          container
              .read(studyControllerProvider.notifier)
              .createCourseFromTopic('数学'),
          throwsA(isA<StudyStructuredOutputException>()),
        );
        expect(llm.calls, hasLength(2));
        expect((await repository.load()).courses, isEmpty);
        expect((await repository.load()).nodes, isEmpty);
      },
    );
  }

  testWidgets(
    'failed grading keeps the answer for retry and does not save a wrong item',
    (tester) async {
      final llm = _ScriptedLlm([
        'not-json',
        '{}',
        '{"correct":true,"partial":false,"score":1,"explanation":"正确"}',
      ]);
      await tester.runAsync(() => prepare(llm: llm));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: QuizPlayerPage(
              topic: '数学',
              items: [
                StudyQuizItem(id: 'q1', stem: '问题一', type: StudyQuizType.short),
                StudyQuizItem(id: 'q2', stem: '问题二', type: StudyQuizType.short),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'answer one');
      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(find.textContaining('批改失败'), findsOneWidget);
      expect(find.text('✗ 错误'), findsNothing);
      expect(find.text('提交'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'answer one',
      );
      expect(
        container.read(studyControllerProvider).requireValue.wrongItems,
        isEmpty,
      );
      final saved = await tester.runAsync(repository.load);
      expect(saved!.wrongItems, isEmpty);

      await tester.tap(find.text('提交'));
      await tester.pumpAndSettle();
      expect(find.text('✓ 正确'), findsOneWidget);
      await tester.tap(find.text('下一题'));
      await tester.pumpAndSettle();
      expect(find.text('问题二'), findsOneWidget);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(llm.calls, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  test('long attachment is summarized before outline generation', () async {
    final llm = _ScriptedLlm([
      '# 摘要\n核心知识',
      '{"title":"课程","children":[{"title":"第一课"}]}',
    ]);
    await prepare(llm: llm);
    final material = '[资料：long.txt]\n${List.filled(13000, 'a').join()}';

    final course = await container
        .read(studyControllerProvider.notifier)
        .createCourseFromTopic('长文课程', material: material);
    final library = container.read(studyControllerProvider).requireValue;

    expect(llm.calls, hasLength(2));
    expect(course.sourceType, StudySourceType.attachment);
    expect(course.sourceSummary, contains('[资料摘要]'));
    expect(course.sourceSummary, contains('核心知识'));
    expect(
      library.nodes.where((node) => node.courseId == course.id),
      isNotEmpty,
    );
  });

  test(
    'node editing cascades deletes and restores an available leaf',
    () async {
      await prepare();
      final course = StudyCourse(id: 'course', title: '课程');
      final current = StudyNode(
        id: 'current',
        courseId: course.id,
        title: '当前',
        progress: StudyNodeProgress.available,
        orderIndex: 0,
      );
      final next = StudyNode(
        id: 'next',
        courseId: course.id,
        title: '下一节',
        progress: StudyNodeProgress.locked,
        orderIndex: 1,
      );
      await repository.save(
        StudyLibrary(courses: [course], nodes: [current, next]),
      );
      await container.read(studyControllerProvider.notifier).reload();
      final controller = container.read(studyControllerProvider.notifier);

      final section = await controller.addNode(
        courseId: course.id,
        title: '附加章节',
        kind: StudyNodeKind.section,
      );
      final child = await controller.addNode(
        courseId: course.id,
        parentId: section.id,
        title: '子知识点',
      );
      await controller.renameNode(child.id, '已重命名');
      var library = container.read(studyControllerProvider).requireValue;
      expect(
        library.nodes.firstWhere((node) => node.id == child.id).title,
        '已重命名',
      );

      await controller.deleteNode(section.id);
      library = container.read(studyControllerProvider).requireValue;
      expect(library.nodes.any((node) => node.id == section.id), isFalse);
      expect(library.nodes.any((node) => node.id == child.id), isFalse);

      await controller.deleteNode(current.id);
      library = container.read(studyControllerProvider).requireValue;
      expect(
        library.nodes.firstWhere((node) => node.id == next.id).progress,
        StudyNodeProgress.available,
      );
    },
  );

  test('wrong item conversion creates one linked card concurrently', () async {
    await prepare();
    final quiz = StudyQuizItem(
      id: 'quiz',
      stem: '1+1?',
      answerText: '2',
      explanation: '基础加法',
    );
    final wrong = StudyWrongItem(quizSnapshot: quiz, userAnswer: '3');
    final controller = container.read(studyControllerProvider.notifier);

    final cards = await Future.wait([
      controller.createCardFromWrong(wrong),
      controller.createCardFromWrong(wrong),
    ]);
    final library = container.read(studyControllerProvider).requireValue;

    expect(cards.first.id, cards.last.id);
    expect(library.cards, hasLength(1));
    expect(library.cards.single.quizItemId, quiz.id);
  });
}
