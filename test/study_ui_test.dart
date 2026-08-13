import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/data/story_models.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/features/study/study_hub_page.dart';
import 'package:expert_chat/features/study/quiz_setup_page.dart';
import 'package:expert_chat/state/chat_controller.dart';
import 'package:expert_chat/state/study_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _StudyUiController extends StudyController {
  @override
  Future<StudyLibrary> build() async {
    final course = StudyCourse(id: 'course', title: '线性代数');
    return StudyLibrary(
      courses: [course],
      nodes: [
        StudyNode(
          courseId: course.id,
          title: '向量',
          orderIndex: 0,
          progress: StudyNodeProgress.done,
        ),
        StudyNode(
          courseId: course.id,
          title: '特征值',
          orderIndex: 1,
          progress: StudyNodeProgress.available,
        ),
      ],
      cards: [StudyCard(front: '什么是特征值？', back: '定义', dueAt: DateTime(2020))],
      wrongItems: [
        StudyWrongItem(
          quizSnapshot: StudyQuizItem(stem: '1+1=?', answerText: '2'),
          userAnswer: '3',
        ),
      ],
    );
  }
}

class _StudyUiChatController extends ChatController {
  @override
  Future<ChatState> build() async => ChatState(
    conversations: [
      Conversation(
        id: 'study-chat',
        title: '学习：特征值',
        mode: ConversationMode.study,
      ),
    ],
  );
}

Widget _subject() => ProviderScope(
  overrides: [
    studyControllerProvider.overrideWith(_StudyUiController.new),
    chatControllerProvider.overrideWith(_StudyUiChatController.new),
  ],
  child: const MaterialApp(home: StudyHubPage()),
);

Widget _quizSubject() => ProviderScope(
  overrides: [studyControllerProvider.overrideWith(_StudyUiController.new)],
  child: const MaterialApp(home: QuizSetupPage()),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('learning workspace stays overflow-free on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_subject());
    await tester.pumpAndSettle();

    expect(find.text('学习空间'), findsOneWidget);
    expect(find.text('导师'), findsOneWidget);
    expect(find.text('课程'), findsOneWidget);
    expect(find.text('刷题'), findsOneWidget);
    expect(find.text('复习'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary study routes share the redesigned visual hierarchy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_subject());
    await tester.pumpAndSettle();
    await tester.tap(find.text('导师').first);
    await tester.pumpAndSettle();

    expect(find.text('找一位适合你的导师'), findsOneWidget);
    expect(find.text('你想学什么？'), findsOneWidget);
    expect(find.text('选择导师方式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('course path remains readable on a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_subject());
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('线性代数'));
    await tester.pumpAndSettle();

    expect(find.text('课程进度'), findsOneWidget);
    expect(find.text('学习路径'), findsOneWidget);
    expect(find.text('特征值'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quiz setup groups scope and settings without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_quizSubject());
    await tester.pumpAndSettle();

    expect(find.text('生成一组刚刚好的练习'), findsOneWidget);
    expect(find.text('练习范围'), findsOneWidget);
    expect(find.text('练习设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
