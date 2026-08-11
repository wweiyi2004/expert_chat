import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:expert_chat/data/db/app_database.dart';
import 'package:expert_chat/data/study_models.dart';
import 'package:expert_chat/data/study_repository.dart';
import 'package:expert_chat/domain/study/study_prompt_assembler.dart';
import 'package:expert_chat/domain/study/tutor_style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase db;
  late SharedPreferences prefs;
  late StudyRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase(NativeDatabase.memory());
    repo = StudyRepository(db, prefs);
  });

  tearDown(() => db.close());

  test('round-trips granular entities and cascades session metadata', () async {
    final now = DateTime.utc(2026, 8, 11, 10);
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'study-chat',
            title: const Value('学习：线性代数'),
            updatedAt: now,
            mode: const Value('study'),
          ),
        );
    final course = StudyCourse(id: 'course-1', title: '线性代数');
    final node = StudyNode(
      id: 'node-1',
      courseId: course.id,
      title: '特征值',
      progress: StudyNodeProgress.available,
    );
    final card = StudyCard(id: 'card-1', front: '定义', back: '解释');
    final quiz = StudyQuizItem(id: 'quiz-1', stem: '1+1?', answerKey: 'B');
    final wrong = StudyWrongItem(
      id: 'wrong-1',
      quizSnapshot: quiz,
      userAnswer: 'A',
    );
    final session = StudySessionMeta(
      conversationId: 'study-chat',
      topic: '线性代数',
      courseId: course.id,
      nodeId: node.id,
      createdAt: now,
    );

    await repo.save(
      StudyLibrary(
        courses: [course],
        nodes: [node],
        cards: [card],
        wrongItems: [wrong],
        sessions: [session],
      ),
    );
    final loaded = await repo.load();

    expect(loaded.courses.single.title, '线性代数');
    expect(loaded.nodes.single.title, '特征值');
    expect(loaded.cards.single.front, '定义');
    expect(loaded.wrongItems.single.quizSnapshot.id, 'quiz-1');
    expect(loaded.sessions.single.courseId, course.id);
    expect(await db.select(db.studyEntities).get(), hasLength(4));

    await (db.delete(
      db.conversations,
    )..where((c) => c.id.equals('study-chat'))).go();
    expect(await repo.getSession('study-chat'), isNull);
  });

  test(
    'concurrent updates merge against the latest committed library',
    () async {
      await repo.load();
      final first = StudyCard(id: 'first', front: 'Q1', back: 'A1');
      final second = StudyCard(id: 'second', front: 'Q2', back: 'A2');

      await Future.wait([
        repo.update((library) {
          return library.copyWith(cards: [first, ...library.cards]);
        }),
        repo.update((library) {
          return library.copyWith(cards: [second, ...library.cards]);
        }),
      ]);

      final loaded = await repo.load();
      expect(loaded.cards.map((card) => card.id).toSet(), {'first', 'second'});
    },
  );

  test('migrates legacy prefs and author-note metadata once', () async {
    final now = DateTime.utc(2026, 8, 11, 11);
    final note = StudyPromptAssembler.encodeSessionNote(
      path: StudyPath.course,
      tutorStyle: TutorStyle.socratic,
      topic: '微积分',
      courseId: 'legacy-course',
      nodeId: 'legacy-node',
    );
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'legacy-chat',
            title: const Value('学习：微积分'),
            updatedAt: now,
            mode: const Value('study'),
            authorNote: Value(note),
          ),
        );
    final legacy = StudyLibrary(
      courses: [StudyCourse(id: 'legacy-course', title: '微积分')],
      nodes: [
        StudyNode(id: 'legacy-node', courseId: 'legacy-course', title: '导数'),
      ],
      cards: [StudyCard(id: 'legacy-card', front: '导数', back: '变化率')],
    );
    await prefs.setString(legacyStudyLibraryKey, jsonEncode(legacy.toJson()));

    final loaded = await repo.load();

    expect(loaded.courses.single.id, 'legacy-course');
    expect(loaded.cards.single.id, 'legacy-card');
    expect(loaded.sessions.single.conversationId, 'legacy-chat');
    expect(loaded.sessions.single.tutorStyle, TutorStyle.socratic);
    expect(prefs.getString(legacyStudyLibraryKey), isNull);
    final conversation = await (db.select(
      db.conversations,
    )..where((c) => c.id.equals('legacy-chat'))).getSingle();
    expect(conversation.authorNote, isEmpty);

    final reloaded = await StudyRepository(db, prefs).load();
    expect(reloaded.courses, hasLength(1));
    expect(reloaded.sessions, hasLength(1));
  });

  test('skips one corrupt entity row without hiding healthy data', () async {
    await repo.load();
    final card = StudyCard(id: 'healthy', front: 'Q', back: 'A');
    await repo.save(StudyLibrary(cards: [card]));
    await db
        .into(db.studyEntities)
        .insert(
          StudyEntitiesCompanion.insert(
            kind: 'course',
            id: 'broken',
            payloadJson: '{not-json',
            sortIndex: const Value(0),
            updatedAt: DateTime.utc(2026, 8, 11),
          ),
        );

    final loaded = await repo.load();
    expect(loaded.cards.single.id, 'healthy');
    expect(loaded.courses, isEmpty);
  });
}
