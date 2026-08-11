import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/models.dart';
import '../data/study_models.dart';
import '../data/study_repository.dart';
import '../domain/llm/llm_provider.dart';
import '../domain/study/course_tree.dart';
import '../domain/study/quiz_codec.dart';
import '../domain/study/srs_scheduler.dart';
import '../domain/study/study_prompt_assembler.dart';
import '../domain/study/structured_output.dart';
import 'settings_controller.dart';

final studyControllerProvider =
    AsyncNotifierProvider<StudyController, StudyLibrary>(StudyController.new);

class StudyController extends AsyncNotifier<StudyLibrary> {
  StudyRepository get _repo => ref.read(studyRepositoryProvider);
  final _prompts = const StudyPromptAssembler();
  final _quiz = const QuizCodec();
  final _tree = const CourseTreeCodec();
  final _srs = const SrsScheduler();

  @override
  Future<StudyLibrary> build() async => _repo.load();

  StudyLibrary get _snapshot => state.value ?? StudyLibrary.empty;

  Future<void> _mutate(
    StudyLibrary Function(StudyLibrary current) mutate,
  ) async {
    final next = await _repo.update(mutate);
    state = AsyncData(next);
  }

  Future<void> reload() async {
    state = AsyncData(await _repo.load());
  }

  Future<void> upsertSession(StudySessionMeta meta) async {
    await _mutate(
      (lib) => lib.copyWith(
        sessions: [
          meta,
          for (final s in lib.sessions)
            if (s.conversationId != meta.conversationId) s,
        ],
      ),
    );
  }

  Future<void> addCards(List<StudyCard> cards) async {
    if (cards.isEmpty) return;
    await _mutate((lib) => lib.copyWith(cards: [...cards, ...lib.cards]));
  }

  Future<void> saveCard(StudyCard card) async {
    await _mutate((lib) {
      final cards = [
        for (final c in lib.cards)
          if (c.id == card.id) card else c,
      ];
      if (!cards.any((c) => c.id == card.id)) cards.insert(0, card);
      return lib.copyWith(cards: cards);
    });
  }

  Future<void> deleteCard(String id) async {
    await _mutate(
      (lib) => lib.copyWith(
        cards: [
          for (final c in lib.cards)
            if (c.id != id) c,
        ],
      ),
    );
  }

  Future<StudyCard> reviewCard(StudyCard card, SrsRating rating) async {
    final next = _srs.apply(card, rating);
    await saveCard(next);
    return next;
  }

  List<StudyCard> dueCards({DateTime? day}) =>
      _srs.dueQueue(_snapshot.cards, day: day);

  Future<void> addWrong(StudyWrongItem item) async {
    await _mutate((lib) {
      final existing = lib.wrongItems.where(
        (w) =>
            w.status == StudyWrongStatus.open &&
            w.quizSnapshot.stem == item.quizSnapshot.stem,
      );
      if (existing.isNotEmpty) {
        final old = existing.first;
        final bumped = old.copyWith(
          missCount: old.missCount + 1,
          userAnswer: item.userAnswer,
          lastMissedAt: DateTime.now(),
        );
        return lib.copyWith(
          wrongItems: [
            bumped,
            for (final w in lib.wrongItems)
              if (w.id != old.id) w,
          ],
        );
      }
      return lib.copyWith(wrongItems: [item, ...lib.wrongItems]);
    });
  }

  Future<void> resolveWrong(String id) async {
    await _mutate(
      (lib) => lib.copyWith(
        wrongItems: [
          for (final w in lib.wrongItems)
            if (w.id == id)
              w.copyWith(status: StudyWrongStatus.resolved)
            else
              w,
        ],
      ),
    );
  }

  Future<void> deleteWrong(String id) async {
    await _mutate(
      (lib) => lib.copyWith(
        wrongItems: [
          for (final w in lib.wrongItems)
            if (w.id != id) w,
        ],
      ),
    );
  }

  Future<StudyCourse> createCourseFromTopic(
    String topic, {
    String material = '',
  }) async {
    final title = topic.trim().isEmpty ? '未命名课程' : topic.trim();
    final sourceSummary = await _prepareCourseMaterial(material);
    final sourceType = material.trim().isEmpty
        ? StudySourceType.topic
        : StudySourceType.attachment;
    ({StudyCourse course, List<StudyNode> nodes})? parsed;
    try {
      parsed = await _completeStructured(
        feature: '课程大纲',
        system: '你是课程设计师。只输出合法 JSON，不要 Markdown 说明。',
        user: _prompts.courseOutlineUserPrompt(
          topic: title,
          material: sourceSummary,
        ),
        parse: (raw) => _tree.parse(
          raw: raw,
          title: title,
          sourceSummary: sourceSummary,
          sourceType: sourceType,
        ),
        isValid: (value) => value != null && value.nodes.isNotEmpty,
      );
    } catch (_) {
      parsed = null;
    }
    final pack =
        parsed ??
        _tree.fallback(
          title: title,
          sourceSummary: sourceSummary,
          sourceType: sourceType,
        );
    await _mutate(
      (lib) => lib.copyWith(
        courses: [pack.course, ...lib.courses],
        nodes: [...pack.nodes, ...lib.nodes],
      ),
    );
    return pack.course;
  }

  Future<void> deleteCourse(String courseId) async {
    await _mutate(
      (lib) => lib.copyWith(
        courses: [
          for (final c in lib.courses)
            if (c.id != courseId) c,
        ],
        nodes: [
          for (final n in lib.nodes)
            if (n.courseId != courseId) n,
        ],
      ),
    );
  }

  List<StudyNode> nodesFor(String courseId) =>
      _snapshot.nodes.where((n) => n.courseId == courseId).toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

  Future<void> saveNode(StudyNode node) async {
    await _mutate((lib) {
      final nodes = [
        for (final n in lib.nodes)
          if (n.id == node.id) node else n,
      ];
      if (!nodes.any((n) => n.id == node.id)) nodes.add(node);
      return lib.copyWith(nodes: nodes);
    });
  }

  Future<StudyNode> addNode({
    required String courseId,
    required String title,
    String? parentId,
    StudyNodeKind kind = StudyNodeKind.leaf,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) throw ArgumentError.value(title, 'title', '标题不能为空');
    late StudyNode created;
    await _mutate((lib) {
      if (!lib.courses.any((course) => course.id == courseId)) {
        throw StateError('课程不存在或已删除');
      }
      if (parentId != null &&
          !lib.nodes.any(
            (node) =>
                node.id == parentId &&
                node.courseId == courseId &&
                node.kind == StudyNodeKind.section,
          )) {
        throw StateError('父级章节不存在');
      }
      final courseNodes = lib.nodes
          .where((node) => node.courseId == courseId)
          .toList();
      final siblings = courseNodes.where((node) => node.parentId == parentId);
      final nextOrder = siblings.isEmpty
          ? 0
          : siblings
                    .map((node) => node.orderIndex)
                    .reduce((a, b) => a > b ? a : b) +
                1;
      final hasActiveLeaf = courseNodes.any(
        (node) =>
            node.kind == StudyNodeKind.leaf &&
            (node.progress == StudyNodeProgress.available ||
                node.progress == StudyNodeProgress.inProgress),
      );
      created = StudyNode(
        courseId: courseId,
        parentId: parentId,
        title: cleanTitle,
        orderIndex: nextOrder,
        kind: kind,
        progress: kind == StudyNodeKind.section
            ? StudyNodeProgress.available
            : hasActiveLeaf
            ? StudyNodeProgress.locked
            : StudyNodeProgress.available,
      );
      return lib.copyWith(nodes: [...lib.nodes, created]);
    });
    return created;
  }

  Future<void> renameNode(String nodeId, String title) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) throw ArgumentError.value(title, 'title', '标题不能为空');
    await _mutate(
      (lib) => lib.copyWith(
        nodes: [
          for (final node in lib.nodes)
            if (node.id == nodeId) node.copyWith(title: cleanTitle) else node,
        ],
      ),
    );
  }

  Future<void> deleteNode(String nodeId) async {
    await _mutate((lib) {
      final target = lib.nodes.where((node) => node.id == nodeId).firstOrNull;
      if (target == null) return lib;
      final removeIds = <String>{nodeId};
      var changed = true;
      while (changed) {
        changed = false;
        for (final node in lib.nodes) {
          if (node.parentId != null &&
              removeIds.contains(node.parentId) &&
              removeIds.add(node.id)) {
            changed = true;
          }
        }
      }
      final remaining = [
        for (final node in lib.nodes)
          if (!removeIds.contains(node.id)) node,
      ];
      final courseLeaves = _tree.leafOrder(
        remaining.where((node) => node.courseId == target.courseId).toList(),
      );
      final hasActive = courseLeaves.any(
        (node) =>
            node.progress == StudyNodeProgress.available ||
            node.progress == StudyNodeProgress.inProgress,
      );
      if (!hasActive) {
        final next = courseLeaves.where(
          (node) => node.progress == StudyNodeProgress.locked,
        );
        if (next.isNotEmpty) {
          final nextId = next.first.id;
          for (var i = 0; i < remaining.length; i++) {
            if (remaining[i].id == nextId) {
              remaining[i] = remaining[i].copyWith(
                progress: StudyNodeProgress.available,
              );
              break;
            }
          }
        }
      }
      return lib.copyWith(nodes: remaining);
    });
  }

  Future<void> completeNode(String nodeId) async {
    await _mutate((lib) {
      final node = lib.nodes.where((n) => n.id == nodeId).firstOrNull;
      if (node == null) return lib;
      final courseNodes = lib.nodes
          .where((n) => n.courseId == node.courseId)
          .toList();
      final updatedCourseNodes = _tree.completeLeaf(courseNodes, nodeId);
      final byId = {for (final n in updatedCourseNodes) n.id: n};
      return lib.copyWith(nodes: [for (final n in lib.nodes) byId[n.id] ?? n]);
    });
  }

  Future<String> ensureNodeExplain({
    required StudyCourse course,
    required StudyNode node,
    bool regenerate = false,
  }) async {
    // Prefer latest row so concurrent progress updates are not clobbered.
    final loaded = await _repo.load();
    final latest =
        loaded.nodes.where((n) => n.id == node.id).firstOrNull ?? node;
    if (!regenerate && latest.explainCache.trim().isNotEmpty) {
      return latest.explainCache;
    }
    final text = await completeText(
      system: '你是耐心的教师，用中文 Markdown 精讲知识点。',
      user: _prompts.nodeExplainUserPrompt(
        courseTitle: course.title,
        nodeTitle: latest.title,
        material: course.sourceSummary,
      ),
    );
    await _mutate((lib) {
      final current =
          lib.nodes.where((n) => n.id == node.id).firstOrNull ?? latest;
      final updated = current.copyWith(explainCache: text);
      return lib.copyWith(
        nodes: [
          for (final existing in lib.nodes)
            if (existing.id == updated.id) updated else existing,
        ],
      );
    });
    return text;
  }

  Future<void> setNodeMastery(String nodeId, StudyMastery mastery) async {
    await _mutate(
      (lib) => lib.copyWith(
        nodes: [
          for (final node in lib.nodes)
            if (node.id == nodeId) node.copyWith(mastery: mastery) else node,
        ],
      ),
    );
  }

  Future<List<StudyQuizItem>> generateQuiz({
    required String topic,
    int count = 5,
    String focus = '',
    String? courseId,
    String? nodeId,
    Set<StudyQuizType>? types,
    int difficulty = 3,
  }) async {
    final requestedTypes = types == null || types.isEmpty
        ? StudyQuizType.values.toSet()
        : types;
    return _completeStructured(
      feature: '测验题',
      system: '你是出题老师。只输出 JSON 数组。',
      user: _prompts.quizGenerateUserPrompt(
        topic: topic,
        count: count,
        focus: focus,
        types: requestedTypes,
        difficulty: difficulty,
      ),
      parse: (raw) => _quiz
          .parseItems(raw, courseId: courseId, nodeId: nodeId)
          .where((item) => requestedTypes.contains(item.type))
          .take(count)
          .toList(),
      isValid: (items) => items.isNotEmpty,
    );
  }

  Future<QuizGrade> gradeItem(StudyQuizItem item, String userAnswer) async {
    final local = _quiz.gradeLocal(item, userAnswer);
    if (local != null) return local;
    try {
      final grade = await _completeStructured<QuizGrade?>(
        feature: '简答题批改',
        system: '你是严谨的阅卷老师。只输出 JSON。',
        user: _prompts.gradeShortUserPrompt(
          stem: item.stem,
          expected: item.answerText.isNotEmpty
              ? item.answerText
              : item.answerKey,
          userAnswer: userAnswer,
        ),
        parse: _quiz.parseGrade,
        isValid: (value) => value != null,
      );
      return grade!;
    } on StudyStructuredOutputException catch (error) {
      return QuizGrade(
        correct: false,
        partial: false,
        explanation: error.rawOutput.trim().isEmpty
            ? '无法自动批改，请对照题目解析人工判断。'
            : '自动批改结构无法识别，以下为模型原始意见：\n${error.rawOutput.trim()}',
        score: 0,
      );
    }
  }

  Future<String> summarizeTranscript(String transcript) => completeText(
    system: '你是学习助理，只输出要点列表。',
    user: _prompts.summaryUserPrompt(transcript: transcript),
  );

  Future<List<StudyCard>> generateCards({
    required String topic,
    required String context,
    int count = 5,
    String? courseId,
    String? nodeId,
  }) async {
    return _completeStructured(
      feature: '复习卡',
      system: '你是制卡助手。只输出 JSON 数组。',
      user: _prompts.cardsFromContextUserPrompt(
        topic: topic,
        context: context,
        count: count,
      ),
      parse: (raw) => _quiz.parseCards(raw, courseId: courseId, nodeId: nodeId),
      isValid: (cards) => cards.isNotEmpty,
    );
  }

  Future<StudyCard> createCardFromWrong(StudyWrongItem wrong) async {
    late StudyCard card;
    await _mutate((lib) {
      final existing = lib.cards.where(
        (candidate) => candidate.quizItemId == wrong.quizSnapshot.id,
      );
      if (existing.isNotEmpty) {
        card = existing.first;
        return lib;
      }
      final quiz = wrong.quizSnapshot;
      final answer = quiz.answerText.trim().isNotEmpty
          ? quiz.answerText.trim()
          : quiz.answerKey.trim();
      card = StudyCard(
        front: quiz.stem,
        back: [
          answer,
          if (quiz.explanation.trim().isNotEmpty) quiz.explanation.trim(),
        ].join('\n\n'),
        hint: '上次作答：${wrong.userAnswer}',
        courseId: quiz.courseId,
        nodeId: quiz.nodeId,
        quizItemId: quiz.id,
      );
      return lib.copyWith(cards: [card, ...lib.cards]);
    });
    return card;
  }

  Future<String> _prepareCourseMaterial(String material) async {
    final source = material.trim();
    if (source.length <= 12000) return source;
    try {
      final summary = await completeText(
        system: '你是课程资料编辑。请用简洁中文 Markdown 输出可用于课程规划的摘要。',
        user:
            '请按原文章节结构提炼核心概念、公式、事实与前置关系；'
            '不得补充原文没有的信息，控制在 2500 字以内。\n\n$source',
      );
      if (summary.trim().isNotEmpty) {
        final sourceLabel = source.split('\n').first.startsWith('[资料：')
            ? '${source.split('\n').first}\n'
            : '';
        return '$sourceLabel[资料摘要]\n${summary.trim()}';
      }
    } catch (_) {
      // The course can still be created from a bounded local excerpt when the
      // summarization request is unavailable.
    }
    return '${source.substring(0, 12000)}\n\n[资料较长，已使用前 12000 字]';
  }

  Future<T> _completeStructured<T>({
    required String feature,
    required String system,
    required String user,
    required T Function(String raw) parse,
    required bool Function(T value) isValid,
  }) async {
    var raw = '';
    Object? cause;
    for (var attempt = 0; attempt < 2; attempt++) {
      raw = await completeText(
        system: attempt == 0
            ? system
            : '$system\n上次输出无法解析。这次必须严格遵守用户给定的 JSON Schema，'
                  '不得输出代码块、前后缀或解释。',
        user: user,
      );
      try {
        final value = parse(raw);
        if (isValid(value)) return value;
        cause = const FormatException('结构为空或缺少必需字段');
      } catch (error) {
        cause = error;
      }
    }
    throw StudyStructuredOutputException(
      feature: feature,
      rawOutput: raw,
      cause: cause,
    );
  }

  /// One-shot completion using the active LLM profile (stream collected).
  Future<String> completeText({
    required String system,
    required String user,
    CancelToken? cancelToken,
  }) async {
    final settings = ref.read(settingsControllerProvider).value;
    if (settings == null || settings.apiKey.trim().isEmpty) {
      throw StateError('请先在设置中配置 API Key');
    }
    final config = LlmConfig(
      baseUrl: settings.baseUrl,
      apiKey: settings.apiKey,
      model: settings.model,
    );
    final buf = StringBuffer();
    await for (final chunk
        in ref
            .read(llmProvider)
            .streamChat(
              config: config,
              messages: [
                LlmRequestMessage(role: MessageRole.system, content: system),
                LlmRequestMessage(role: MessageRole.user, content: user),
              ],
              cancelToken: cancelToken,
            )) {
      if (chunk.contentDelta != null) buf.write(chunk.contentDelta);
    }
    return buf.toString().trim();
  }
}

// Dart 3 iterable helper if missing on older — use extension fallback.
extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}
