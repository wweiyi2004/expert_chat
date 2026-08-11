import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/provider_profile.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/data/study_repository.dart';
import 'package:expert_chat/domain/llm/llm_provider.dart';
import 'package:expert_chat/domain/study/structured_output.dart';
import 'package:expert_chat/state/settings_controller.dart';
import 'package:expert_chat/state/study_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadySettings extends SettingsController {
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
      apiKey: 'sk-test',
    );
  }
}

class _ScriptedLlm implements LlmProvider {
  _ScriptedLlm(this.responses);

  final List<String> responses;
  final List<List<LlmRequestMessage>> calls = [];

  @override
  Stream<ChatChunk> streamChat({
    required LlmConfig config,
    required List<LlmRequestMessage> messages,
    List<ToolSpec>? tools,
    bool? thinking,
    String? forceToolName,
    CancelToken? cancelToken,
  }) async* {
    calls.add(List.of(messages));
    final index = (calls.length - 1).clamp(0, responses.length - 1);
    yield ChatChunk(contentDelta: responses[index]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late StudyRepository repository;
  late ProviderContainer container;

  Future<void> prepare({LlmProvider? llm}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase(NativeDatabase.memory());
    repository = StudyRepository(db, prefs);
    container = ProviderContainer(
      overrides: [
        studyRepositoryProvider.overrideWithValue(repository),
        settingsControllerProvider.overrideWith(_ReadySettings.new),
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
    'short-answer grading retries then exposes readable raw advice',
    () async {
      final llm = _ScriptedLlm(['not-json', '原始批改意见']);
      await prepare(llm: llm);
      final item = StudyQuizItem(
        stem: '解释惯性',
        type: StudyQuizType.short,
        answerText: '物体保持运动状态的性质',
      );

      final grade = await container
          .read(studyControllerProvider.notifier)
          .gradeItem(item, '不完整回答');

      expect(llm.calls, hasLength(2));
      expect(grade.correct, isFalse);
      expect(grade.explanation, contains('原始批改意见'));
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
