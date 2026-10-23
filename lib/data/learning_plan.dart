import 'dart:convert';

class LearningKnowledge {
  const LearningKnowledge({
    required this.id,
    required this.title,
    required this.criterion,
    required this.source,
    this.minutes = 30,
  });
  final String id, title, criterion, source;
  final int minutes;
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'criterion': criterion,
    'source': source,
    'minutes': minutes,
  };
  factory LearningKnowledge.fromJson(Map<String, dynamic> j) =>
      LearningKnowledge(
        id: j['id'] as String,
        title: j['title'] as String,
        criterion: j['criterion'] as String? ?? '能够独立解释并解题',
        source: j['source'] as String? ?? '待核对',
        minutes: ((j['minutes'] as num?)?.toInt() ?? 30).clamp(5, 240),
      );
}

class LearningFeedback {
  const LearningFeedback({
    required this.answer,
    required this.assessment,
    required this.date,
    this.passed = const [],
    this.needsReview = const [],
  });
  final String answer, assessment, date;
  final List<String> passed, needsReview;
  Map<String, dynamic> toJson() => {
    'answer': answer,
    'assessment': assessment,
    'date': date,
    'passed': passed,
    'needsReview': needsReview,
  };
  factory LearningFeedback.fromJson(Map<String, dynamic> j) => LearningFeedback(
    answer: j['answer'] as String,
    assessment: j['assessment'] as String,
    date: j['date'] as String,
    passed: (j['passed'] as List? ?? []).cast<String>(),
    needsReview: (j['needsReview'] as List? ?? []).cast<String>(),
  );
}

class LearningLesson {
  const LearningLesson({
    required this.date,
    required this.knowledgeIds,
    required this.content,
    this.feedback = const [],
  });
  final String date, content;
  final List<String> knowledgeIds;
  final List<LearningFeedback> feedback;
  Map<String, dynamic> toJson() => {
    'date': date,
    'knowledgeIds': knowledgeIds,
    'content': content,
    'feedback': [for (final f in feedback) f.toJson()],
  };
  factory LearningLesson.fromJson(Map<String, dynamic> j) => LearningLesson(
    date: j['date'] as String,
    content: j['content'] as String,
    knowledgeIds: (j['knowledgeIds'] as List).cast<String>(),
    feedback: [
      for (final f in j['feedback'] as List? ?? [])
        LearningFeedback.fromJson(Map<String, dynamic>.from(f as Map)),
    ],
  );
}

class LearningPlan {
  const LearningPlan({
    required this.id,
    required this.topic,
    required this.goal,
    required this.deadline,
    required this.dailyMinutes,
    required this.foundation,
    required this.material,
    required this.knowledge,
    required this.schedule,
    this.lessons = const [],
  });
  final String id, topic, goal, deadline, material, schedule;
  final int dailyMinutes;
  final bool foundation;
  final List<LearningKnowledge> knowledge;
  final List<LearningLesson> lessons;
  LearningPlan withLessons(List<LearningLesson> value) => LearningPlan(
    id: id,
    topic: topic,
    goal: goal,
    deadline: deadline,
    dailyMinutes: dailyMinutes,
    foundation: foundation,
    material: material,
    knowledge: knowledge,
    schedule: schedule,
    lessons: value,
  );

  /// Only actual submissions change verification status. Later evidence wins.
  Map<String, bool> get evidence {
    final result = <String, bool>{};
    final history = lessons.expand((l) => l.feedback).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    for (final feedback in history) {
      for (final id in feedback.passed) {
        result[id] = true;
      }
      for (final id in feedback.needsReview) {
        result[id] = false;
      }
    }
    return result;
  }

  List<LearningKnowledge> nextKnowledge() {
    final verified = evidence;
    final candidates = [
      ...knowledge.where((k) => verified[k.id] == false),
      ...knowledge.where((k) => !verified.containsKey(k.id)),
    ];
    if (candidates.isEmpty) candidates.addAll(knowledge);
    var used = 0;
    final result = <LearningKnowledge>[];
    for (final item in candidates) {
      if (result.isNotEmpty && used + item.minutes > dailyMinutes) break;
      result.add(item);
      used += item.minutes;
      if (used >= dailyMinutes) break;
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'topic': topic,
    'goal': goal,
    'deadline': deadline,
    'dailyMinutes': dailyMinutes,
    'foundation': foundation,
    'material': material,
    'knowledge': [for (final k in knowledge) k.toJson()],
    'schedule': schedule,
    'lessons': [for (final l in lessons) l.toJson()],
  };
  factory LearningPlan.fromJson(Map<String, dynamic> j) => LearningPlan(
    id: j['id'] as String,
    topic: j['topic'] as String,
    goal: j['goal'] as String,
    deadline: j['deadline'] as String,
    dailyMinutes: j['dailyMinutes'] as int,
    foundation: j['foundation'] as bool,
    material: j['material'] as String,
    schedule: j['schedule'] as String,
    knowledge: [
      for (final k in j['knowledge'] as List)
        LearningKnowledge.fromJson(Map<String, dynamic>.from(k as Map)),
    ],
    lessons: [
      for (final l in j['lessons'] as List? ?? [])
        LearningLesson.fromJson(Map<String, dynamic>.from(l as Map)),
    ],
  );
}

Map<String, dynamic> learningJson(String text) {
  final raw = text
      .trim()
      .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
      .replaceFirst(RegExp(r'\s*```$'), '');
  return Map<String, dynamic>.from(jsonDecode(raw) as Map);
}
