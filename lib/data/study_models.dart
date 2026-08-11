import 'package:uuid/uuid.dart';

import '../domain/study/tutor_style.dart';

const _uuid = Uuid();

enum StudySourceType {
  topic,
  attachment;

  String get wire => name;
  static StudySourceType fromWire(String? v) =>
      v == attachment.wire ? attachment : topic;
}

enum StudyNodeKind {
  section,
  leaf;

  String get wire => name;
  static StudyNodeKind fromWire(String? v) =>
      v == section.wire ? section : leaf;
}

enum StudyNodeProgress {
  locked,
  available,
  inProgress,
  done;

  String get wire => switch (this) {
    locked => 'locked',
    available => 'available',
    inProgress => 'in_progress',
    done => 'done',
  };

  static StudyNodeProgress fromWire(String? v) => switch (v) {
    'locked' => locked,
    'in_progress' => inProgress,
    'done' => done,
    _ => available,
  };
}

enum StudyMastery {
  weak,
  familiar,
  mastered;

  String get wire => name;
  String get label => switch (this) {
    weak => '生疏',
    familiar => '了解',
    mastered => '掌握',
  };

  static StudyMastery? fromWire(String? v) {
    if (v == null || v.isEmpty) return null;
    for (final m in values) {
      if (m.wire == v) return m;
    }
    return null;
  }
}

enum StudyQuizType {
  single,
  boolType,
  cloze,
  short;

  String get wire => switch (this) {
    single => 'single',
    boolType => 'bool',
    cloze => 'cloze',
    short => 'short',
  };

  static StudyQuizType fromWire(String? v) => switch (v) {
    'bool' || 'boolean' || 'judge' => boolType,
    'cloze' || 'fill' => cloze,
    'short' || 'essay' => short,
    _ => single,
  };
}

enum StudyWrongStatus {
  open,
  resolved;

  String get wire => name;
  static StudyWrongStatus fromWire(String? v) =>
      v == resolved.wire ? resolved : open;
}

bool? _parseBooleanValue(Object? value) {
  if (value is bool) return value;
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'true' || '1' || 'yes' || 'y' || '正确' || '对' || '是' => true,
    'false' || '0' || 'no' || 'n' || '错误' || '错' || '否' => false,
    _ => null,
  };
}

class StudyCourse {
  StudyCourse({
    String? id,
    required this.title,
    this.sourceType = StudySourceType.topic,
    this.sourceSummary = '',
    this.status = 'active',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final StudySourceType sourceType;
  final String sourceSummary;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;

  StudyCourse copyWith({
    String? title,
    String? sourceSummary,
    String? status,
    DateTime? updatedAt,
  }) => StudyCourse(
    id: id,
    title: title ?? this.title,
    sourceType: sourceType,
    sourceSummary: sourceSummary ?? this.sourceSummary,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'sourceType': sourceType.wire,
    'sourceSummary': sourceSummary,
    'status': status,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory StudyCourse.fromJson(Map<String, dynamic> json) => StudyCourse(
    id: json['id'] as String?,
    title: (json['title'] ?? '').toString(),
    sourceType: StudySourceType.fromWire(json['sourceType'] as String?),
    sourceSummary: (json['sourceSummary'] ?? '').toString(),
    status: (json['status'] ?? 'active').toString(),
    createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
    updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()),
  );
}

class StudyNode {
  StudyNode({
    String? id,
    required this.courseId,
    this.parentId,
    required this.title,
    this.orderIndex = 0,
    this.kind = StudyNodeKind.leaf,
    this.explainCache = '',
    this.mastery,
    this.progress = StudyNodeProgress.locked,
  }) : id = id ?? _uuid.v4();

  final String id;
  final String courseId;
  final String? parentId;
  final String title;
  final int orderIndex;
  final StudyNodeKind kind;
  final String explainCache;
  final StudyMastery? mastery;
  final StudyNodeProgress progress;

  /// Entering an available lesson starts it. Reopening completed or already
  /// active lessons preserves their persisted progress.
  StudyNode markStarted() => progress == StudyNodeProgress.available
      ? copyWith(progress: StudyNodeProgress.inProgress)
      : this;

  StudyNode copyWith({
    String? parentId,
    String? title,
    int? orderIndex,
    StudyNodeKind? kind,
    String? explainCache,
    Object? mastery = _sentinel,
    StudyNodeProgress? progress,
  }) => StudyNode(
    id: id,
    courseId: courseId,
    parentId: parentId ?? this.parentId,
    title: title ?? this.title,
    orderIndex: orderIndex ?? this.orderIndex,
    kind: kind ?? this.kind,
    explainCache: explainCache ?? this.explainCache,
    mastery: identical(mastery, _sentinel)
        ? this.mastery
        : mastery as StudyMastery?,
    progress: progress ?? this.progress,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'courseId': courseId,
    'parentId': parentId,
    'title': title,
    'orderIndex': orderIndex,
    'kind': kind.wire,
    'explainCache': explainCache,
    'mastery': mastery?.wire,
    'progress': progress.wire,
  };

  factory StudyNode.fromJson(Map<String, dynamic> json) => StudyNode(
    id: json['id'] as String?,
    courseId: (json['courseId'] ?? '').toString(),
    parentId: json['parentId'] as String?,
    title: (json['title'] ?? '').toString(),
    orderIndex: (json['orderIndex'] as num?)?.toInt() ?? 0,
    kind: StudyNodeKind.fromWire(json['kind'] as String?),
    explainCache: (json['explainCache'] ?? '').toString(),
    mastery: StudyMastery.fromWire(json['mastery'] as String?),
    progress: StudyNodeProgress.fromWire(json['progress'] as String?),
  );

  static const _sentinel = Object();
}

class StudyQuizItem {
  StudyQuizItem({
    String? id,
    required this.stem,
    this.type = StudyQuizType.single,
    List<String>? options,
    this.answerKey = '',
    this.answerText = '',
    this.explanation = '',
    this.difficulty = 3,
    this.nodeId,
    this.courseId,
    DateTime? createdAt,
  }) : id = id ?? _uuid.v4(),
       options = options ?? const [],
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String stem;
  final StudyQuizType type;
  final List<String> options;
  final String answerKey;
  final String answerText;
  final String explanation;
  final int difficulty;
  final String? nodeId;
  final String? courseId;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'stem': stem,
    'type': type.wire,
    'options': options,
    'answerKey': answerKey,
    'answerText': answerText,
    'explanation': explanation,
    'difficulty': difficulty,
    'nodeId': nodeId,
    'courseId': courseId,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StudyQuizItem.fromJson(Map<String, dynamic> json) => StudyQuizItem(
    id: json['id'] as String?,
    stem: (json['stem'] ?? '').toString(),
    type: StudyQuizType.fromWire(json['type'] as String?),
    options:
        (json['options'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    answerKey: (json['answerKey'] ?? '').toString(),
    answerText: (json['answerText'] ?? json['answer'] ?? '').toString(),
    explanation: (json['explanation'] ?? '').toString(),
    difficulty: ((json['difficulty'] as num?)?.toInt() ?? 3).clamp(1, 5),
    nodeId: json['nodeId'] as String?,
    courseId: json['courseId'] as String?,
    createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
  );

  /// Loose map from model JSON.
  static StudyQuizItem? fromModelMap(
    Map<String, dynamic> map, {
    String? courseId,
    String? nodeId,
  }) {
    final stem = (map['stem'] ?? map['question'] ?? map['q'] ?? '')
        .toString()
        .trim();
    if (stem.isEmpty) return null;
    final type = StudyQuizType.fromWire(
      (map['type'] ?? map['kind'] ?? 'single').toString(),
    );
    final options =
        (map['options'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final answerRaw = map['answer'] ?? map['answerKey'] ?? map['correct'];
    var answerKey = '';
    var answerText = '';
    if (answerRaw != null) {
      final a = answerRaw.toString().trim();
      answerText = a;
      final booleanAnswer = type == StudyQuizType.boolType
          ? _parseBooleanValue(answerRaw)
          : null;
      if (booleanAnswer != null && options.isNotEmpty) {
        final idx = options.indexWhere(
          (option) => _parseBooleanValue(option) == booleanAnswer,
        );
        if (idx >= 0) {
          answerKey = String.fromCharCode(65 + idx);
          answerText = options[idx];
        } else {
          answerKey = a;
        }
      } else if (RegExp(r'^[A-Da-d]$').hasMatch(a)) {
        // If answer is A/B/C index label.
        answerKey = a.toUpperCase();
        final idx = answerKey.codeUnitAt(0) - 65;
        if (idx >= 0 && idx < options.length) {
          answerText = options[idx];
        }
      } else if (options.isNotEmpty) {
        final idx = options.indexWhere(
          (o) => o.trim().toLowerCase() == a.toLowerCase(),
        );
        if (idx >= 0) {
          answerKey = String.fromCharCode(65 + idx);
          answerText = options[idx];
        } else {
          answerKey = a;
        }
      } else {
        answerKey = a;
      }
    }
    return StudyQuizItem(
      stem: stem,
      type: type,
      options: options,
      answerKey: answerKey,
      answerText: answerText,
      explanation: (map['explanation'] ?? map['解析'] ?? '').toString(),
      difficulty: ((map['difficulty'] as num?)?.toInt() ?? 3).clamp(1, 5),
      courseId: courseId ?? map['courseId'] as String?,
      nodeId: nodeId ?? map['nodeId'] as String?,
    );
  }
}

class StudyWrongItem {
  StudyWrongItem({
    String? id,
    required this.quizSnapshot,
    this.userAnswer = '',
    this.missCount = 1,
    this.status = StudyWrongStatus.open,
    DateTime? lastMissedAt,
  }) : id = id ?? _uuid.v4(),
       lastMissedAt = lastMissedAt ?? DateTime.now();

  final String id;
  final StudyQuizItem quizSnapshot;
  final String userAnswer;
  final int missCount;
  final StudyWrongStatus status;
  final DateTime lastMissedAt;

  StudyWrongItem copyWith({
    String? userAnswer,
    int? missCount,
    StudyWrongStatus? status,
    DateTime? lastMissedAt,
  }) => StudyWrongItem(
    id: id,
    quizSnapshot: quizSnapshot,
    userAnswer: userAnswer ?? this.userAnswer,
    missCount: missCount ?? this.missCount,
    status: status ?? this.status,
    lastMissedAt: lastMissedAt ?? this.lastMissedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'quizSnapshot': quizSnapshot.toJson(),
    'userAnswer': userAnswer,
    'missCount': missCount,
    'status': status.wire,
    'lastMissedAt': lastMissedAt.toIso8601String(),
  };

  factory StudyWrongItem.fromJson(Map<String, dynamic> json) => StudyWrongItem(
    id: json['id'] as String?,
    quizSnapshot: StudyQuizItem.fromJson(
      Map<String, dynamic>.from(json['quizSnapshot'] as Map? ?? {}),
    ),
    userAnswer: (json['userAnswer'] ?? '').toString(),
    missCount: (json['missCount'] as num?)?.toInt() ?? 1,
    status: StudyWrongStatus.fromWire(json['status'] as String?),
    lastMissedAt: DateTime.tryParse((json['lastMissedAt'] ?? '').toString()),
  );
}

class StudyCard {
  StudyCard({
    String? id,
    required this.front,
    required this.back,
    this.hint = '',
    this.ease = 2.5,
    this.intervalDays = 0,
    this.repetitions = 0,
    DateTime? dueAt,
    this.lastReviewedAt,
    this.courseId,
    this.nodeId,
    this.quizItemId,
    this.suspended = false,
    DateTime? createdAt,
  }) : id = id ?? _uuid.v4(),
       dueAt = dueAt ?? DateTime.now(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String front;
  final String back;
  final String hint;
  final double ease;
  final int intervalDays;
  final int repetitions;
  final DateTime dueAt;
  final DateTime? lastReviewedAt;
  final String? courseId;
  final String? nodeId;
  final String? quizItemId;
  final bool suspended;
  final DateTime createdAt;

  StudyCard copyWith({
    String? front,
    String? back,
    String? hint,
    double? ease,
    int? intervalDays,
    int? repetitions,
    DateTime? dueAt,
    Object? lastReviewedAt = _sentinel,
    bool? suspended,
  }) => StudyCard(
    id: id,
    front: front ?? this.front,
    back: back ?? this.back,
    hint: hint ?? this.hint,
    ease: ease ?? this.ease,
    intervalDays: intervalDays ?? this.intervalDays,
    repetitions: repetitions ?? this.repetitions,
    dueAt: dueAt ?? this.dueAt,
    lastReviewedAt: identical(lastReviewedAt, _sentinel)
        ? this.lastReviewedAt
        : lastReviewedAt as DateTime?,
    courseId: courseId,
    nodeId: nodeId,
    quizItemId: quizItemId,
    suspended: suspended ?? this.suspended,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'front': front,
    'back': back,
    'hint': hint,
    'ease': ease,
    'intervalDays': intervalDays,
    'repetitions': repetitions,
    'dueAt': dueAt.toIso8601String(),
    'lastReviewedAt': lastReviewedAt?.toIso8601String(),
    'courseId': courseId,
    'nodeId': nodeId,
    'quizItemId': quizItemId,
    'suspended': suspended,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StudyCard.fromJson(Map<String, dynamic> json) => StudyCard(
    id: json['id'] as String?,
    front: (json['front'] ?? '').toString(),
    back: (json['back'] ?? '').toString(),
    hint: (json['hint'] ?? '').toString(),
    ease: (json['ease'] as num?)?.toDouble() ?? 2.5,
    intervalDays: (json['intervalDays'] as num?)?.toInt() ?? 0,
    repetitions: (json['repetitions'] as num?)?.toInt() ?? 0,
    dueAt: DateTime.tryParse((json['dueAt'] ?? '').toString()),
    lastReviewedAt: DateTime.tryParse(
      (json['lastReviewedAt'] ?? '').toString(),
    ),
    courseId: json['courseId'] as String?,
    nodeId: json['nodeId'] as String?,
    quizItemId: json['quizItemId'] as String?,
    suspended: json['suspended'] == true,
    createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
  );

  static const _sentinel = Object();
}

class StudySessionMeta {
  StudySessionMeta({
    required this.conversationId,
    this.path = StudyPath.tutor,
    this.tutorStyle = TutorStyle.mixed,
    this.topic = '',
    this.courseId,
    this.nodeId,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String conversationId;
  final StudyPath path;
  final TutorStyle tutorStyle;
  final String topic;
  final String? courseId;
  final String? nodeId;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'conversationId': conversationId,
    'path': path.wire,
    'tutorStyle': tutorStyle.wire,
    'topic': topic,
    'courseId': courseId,
    'nodeId': nodeId,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StudySessionMeta.fromJson(Map<String, dynamic> json) =>
      StudySessionMeta(
        conversationId: (json['conversationId'] ?? '').toString(),
        path: StudyPath.fromWire(json['path'] as String?),
        tutorStyle: TutorStyle.fromWire(json['tutorStyle'] as String?),
        topic: (json['topic'] ?? '').toString(),
        courseId: json['courseId'] as String?,
        nodeId: json['nodeId'] as String?,
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
      );
}

/// Root document persisted by [StudyRepository].
class StudyLibrary {
  const StudyLibrary({
    this.courses = const [],
    this.nodes = const [],
    this.cards = const [],
    this.wrongItems = const [],
    this.sessions = const [],
  });

  final List<StudyCourse> courses;
  final List<StudyNode> nodes;
  final List<StudyCard> cards;
  final List<StudyWrongItem> wrongItems;
  final List<StudySessionMeta> sessions;

  StudyLibrary copyWith({
    List<StudyCourse>? courses,
    List<StudyNode>? nodes,
    List<StudyCard>? cards,
    List<StudyWrongItem>? wrongItems,
    List<StudySessionMeta>? sessions,
  }) => StudyLibrary(
    courses: courses ?? this.courses,
    nodes: nodes ?? this.nodes,
    cards: cards ?? this.cards,
    wrongItems: wrongItems ?? this.wrongItems,
    sessions: sessions ?? this.sessions,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'courses': courses.map((e) => e.toJson()).toList(),
    'nodes': nodes.map((e) => e.toJson()).toList(),
    'cards': cards.map((e) => e.toJson()).toList(),
    'wrongItems': wrongItems.map((e) => e.toJson()).toList(),
    'sessions': sessions.map((e) => e.toJson()).toList(),
  };

  factory StudyLibrary.fromJson(Map<String, dynamic> json) => StudyLibrary(
    courses: (json['courses'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => StudyCourse.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    nodes: (json['nodes'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => StudyNode.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    cards: (json['cards'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => StudyCard.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    wrongItems: (json['wrongItems'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => StudyWrongItem.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    sessions: (json['sessions'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => StudySessionMeta.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );

  static const empty = StudyLibrary();
}
