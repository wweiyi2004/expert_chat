import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

enum TaskPlanStatus { tracking, awaitingApproval, approved, cancelled }

enum PlanStepStatus { pending, running, completed, cancelled }

class PlanStep {
  const PlanStep({
    required this.id,
    required this.title,
    this.status = PlanStepStatus.pending,
    this.evidence = const [],
    this.verified = false,
  });
  final String id, title;
  final PlanStepStatus status;
  final List<String> evidence;
  final bool verified;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'status': status.name,
    'evidence': evidence,
    'verified': verified,
  };
  factory PlanStep.fromJson(Map<String, dynamic> j) {
    if (j['id'] is! String ||
        (j['id'] as String).isEmpty ||
        j['title'] is! String ||
        (j['title'] as String).trim().isEmpty ||
        (j['title'] as String).length > 500) {
      throw const FormatException('Invalid plan step');
    }
    return PlanStep(
      id: j['id'] as String,
      title: j['title'] as String,
      status: PlanStepStatus.values.byName(j['status'] as String? ?? 'pending'),
      evidence: (j['evidence'] as List? ?? []).cast<String>(),
      verified: j['verified'] == true,
    );
  }
}

class TaskPlan {
  TaskPlan({
    required this.id,
    required this.conversationId,
    required this.revision,
    required this.goal,
    required this.body,
    required this.steps,
    required this.status,
    required this.requiresReview,
    required this.target,
    this.taskId,
    this.approvedRevision,
    this.approvedBy,
    this.comments = const [],
    this.history = const [],
    this.criteria = const {},
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now().toUtc();
  final String id, conversationId, goal, body;
  final String? taskId, approvedBy;
  final int revision;
  final int? approvedRevision;
  final bool requiresReview;
  final TaskPlanStatus status;
  final List<PlanStep> steps;
  final Map<String, dynamic> target;
  final Map<String, dynamic> criteria;
  final List<Map<String, dynamic>> comments, history;
  final DateTime updatedAt;
  bool activeFor(String? root, String? userGoal) =>
      status != TaskPlanStatus.cancelled &&
      (taskId == root && root != null ||
          taskId == null && userGoal?.trim() == goal.trim());
  bool get approved =>
      status == TaskPlanStatus.approved && approvedRevision == revision;
  String get contentHash => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'goal': goal,
            'body': body,
            'steps': steps.map((s) => {'id': s.id, 'title': s.title}).toList(),
            'comments': comments,
            'target': target,
            'criteria': criteria,
          }),
        ),
      )
      .toString();
  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'revision': revision,
    'goal': goal,
    'body': body,
    'steps': steps.map((s) => s.toJson()).toList(),
    'status': status.name,
    'requiresReview': requiresReview,
    'target': target,
    'taskId': taskId,
    'approvedRevision': approvedRevision,
    'approvedBy': approvedBy,
    'comments': comments,
    'history': history,
    'criteria': criteria,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory TaskPlan.fromJson(Map<String, dynamic> j) {
    if (j['id'] is! String ||
        j['conversationId'] is! String ||
        j['revision'] is! int ||
        (j['revision'] as int) < 1 ||
        j['goal'] is! String ||
        j['body'] is! String ||
        (j['body'] as String).length > 32000 ||
        (j['goal'] as String).length > 12000 ||
        j['steps'] is! List ||
        (j['steps'] as List).length > 32) {
      throw const FormatException('Invalid plan');
    }
    final steps = (j['steps'] as List)
        .map((s) => PlanStep.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();
    if (steps.map((s) => s.id).toSet().length != steps.length) {
      throw const FormatException('Duplicate plan step');
    }
    if ((j['id'] as String).isEmpty ||
        (j['id'] as String).length > 200 ||
        (j['conversationId'] as String).isEmpty ||
        (j['conversationId'] as String).length > 200 ||
        (j['comments'] as List? ?? []).length > 100 ||
        (j['history'] as List? ?? []).length > 20 ||
        jsonEncode(j).length > 1000000) {
      throw const FormatException('Plan size exceeded');
    }
    for (final raw in j['comments'] as List? ?? []) {
      if (raw is! Map ||
          raw['text'] is! String ||
          (raw['text'] as String).length > 2000 ||
          raw['version'] is! int ||
          raw['author'] != 'user') {
        throw const FormatException('Invalid plan comment');
      }
    }
    if (j['status'] == 'approved' &&
        (j['approvedRevision'] != j['revision'] ||
            j['approvedBy'] != 'user' ||
            j['requiresReview'] != true)) {
      throw const FormatException('Invalid plan approval');
    }
    return TaskPlan(
      id: j['id'] as String,
      conversationId: j['conversationId'] as String,
      revision: j['revision'] as int,
      goal: j['goal'] as String,
      body: j['body'] as String,
      steps: steps,
      status: TaskPlanStatus.values.byName(j['status'] as String),
      requiresReview: j['requiresReview'] == true,
      target: Map<String, dynamic>.from(j['target'] as Map? ?? {}),
      criteria: Map<String, dynamic>.from(j['criteria'] as Map? ?? {}),
      taskId: j['taskId'] as String?,
      approvedRevision: j['approvedRevision'] as int?,
      approvedBy: j['approvedBy'] as String?,
      comments: (j['comments'] as List? ?? [])
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList(),
      history: (j['history'] as List? ?? [])
          .take(20)
          .map((c) => Map<String, dynamic>.from(c as Map))
          .toList(),
      updatedAt: DateTime.parse(j['updatedAt'] as String),
    );
  }
  TaskPlan replace(Map<String, dynamic> fields) => TaskPlan.fromJson({
    ...toJson(),
    ...fields,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });
  static List<PlanStep> stepsFromTitles(List<String> titles) => titles
      .map((title) => PlanStep(id: const Uuid().v4(), title: title.trim()))
      .toList();
}
