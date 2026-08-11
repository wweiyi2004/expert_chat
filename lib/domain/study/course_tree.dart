import 'dart:convert';

import '../../data/study_models.dart';
import 'quiz_codec.dart';

/// Parse AI-generated course outlines into [StudyCourse] + [StudyNode] trees.
class CourseTreeCodec {
  const CourseTreeCodec();

  static const int maxNodes = 40;

  /// Build course + nodes from model JSON. Returns null if unusable.
  ({StudyCourse course, List<StudyNode> nodes})? parse({
    required String raw,
    required String title,
    String sourceSummary = '',
    StudySourceType sourceType = StudySourceType.topic,
  }) {
    final blob = QuizCodec.extractJsonBlob(raw);
    if (blob == null) return null;
    try {
      final decoded = jsonDecode(blob);
      if (decoded is! Map && decoded is! List) return null;

      final course = StudyCourse(
        title: title.trim().isEmpty ? '未命名课程' : title.trim(),
        sourceType: sourceType,
        sourceSummary: sourceSummary,
      );

      final nodes = <StudyNode>[];
      if (decoded is List) {
        _walkList(
          decoded,
          courseId: course.id,
          parentId: null,
          nodes: nodes,
          orderBase: 0,
        );
      } else {
        final map = Map<String, dynamic>.from(decoded);
        final rootTitle = (map['title'] ?? map['name'] ?? title).toString();
        final children = map['children'] ?? map['nodes'] ?? map['chapters'];
        if (children is List) {
          _walkList(
            children,
            courseId: course.id,
            parentId: null,
            nodes: nodes,
            orderBase: 0,
          );
        } else {
          // Single leaf course.
          nodes.add(
            StudyNode(
              courseId: course.id,
              parentId: null,
              title: rootTitle,
              orderIndex: 0,
              kind: StudyNodeKind.leaf,
              progress: StudyNodeProgress.available,
            ),
          );
        }
      }

      if (nodes.isEmpty) {
        nodes.add(
          StudyNode(
            courseId: course.id,
            parentId: null,
            title: '第 1 课',
            orderIndex: 0,
            kind: StudyNodeKind.leaf,
            progress: StudyNodeProgress.available,
          ),
        );
      }

      // Ensure at least one available leaf.
      final leaves = nodes.where((n) => n.kind == StudyNodeKind.leaf).toList();
      if (leaves.isEmpty) {
        // Promote all nodes without children to leaves.
        final childParents = nodes
            .map((n) => n.parentId)
            .whereType<String>()
            .toSet();
        for (var i = 0; i < nodes.length; i++) {
          if (!childParents.contains(nodes[i].id)) {
            nodes[i] = nodes[i].copyWith(
              kind: StudyNodeKind.leaf,
              progress: StudyNodeProgress.available,
            );
          }
        }
      } else {
        // First leaf available, rest locked if after first.
        var first = true;
        for (var i = 0; i < nodes.length; i++) {
          if (nodes[i].kind != StudyNodeKind.leaf) continue;
          nodes[i] = nodes[i].copyWith(
            progress: first
                ? StudyNodeProgress.available
                : StudyNodeProgress.locked,
          );
          first = false;
        }
      }

      if (nodes.length > maxNodes) {
        nodes.removeRange(maxNodes, nodes.length);
      }
      return (course: course, nodes: nodes);
    } catch (_) {
      return null;
    }
  }

  void _walkList(
    List list, {
    required String courseId,
    required String? parentId,
    required List<StudyNode> nodes,
    required int orderBase,
  }) {
    for (var i = 0; i < list.length; i++) {
      if (nodes.length >= maxNodes) return;
      final entry = list[i];
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final title = (map['title'] ?? map['name'] ?? '节点 ${orderBase + i + 1}')
          .toString()
          .trim();
      final children = map['children'] ?? map['nodes'] ?? map['sections'];
      final hasChildren = children is List && children.isNotEmpty;
      final node = StudyNode(
        courseId: courseId,
        parentId: parentId,
        title: title.isEmpty ? '未命名' : title,
        orderIndex: orderBase + i,
        kind: hasChildren ? StudyNodeKind.section : StudyNodeKind.leaf,
        progress: hasChildren
            ? StudyNodeProgress.available
            : StudyNodeProgress.locked,
        explainCache: (map['explain'] ?? map['summary'] ?? '').toString(),
      );
      nodes.add(node);
      if (hasChildren) {
        _walkList(
          children,
          courseId: courseId,
          parentId: node.id,
          nodes: nodes,
          orderBase: 0,
        );
      }
    }
  }

  /// Fallback mini course when AI parse fails.
  ({StudyCourse course, List<StudyNode> nodes}) fallback({
    required String title,
    String sourceSummary = '',
    StudySourceType sourceType = StudySourceType.topic,
  }) {
    final course = StudyCourse(
      title: title.trim().isEmpty ? '未命名课程' : title.trim(),
      sourceType: sourceType,
      sourceSummary: sourceSummary,
    );
    final node = StudyNode(
      courseId: course.id,
      parentId: null,
      title: '入门',
      orderIndex: 0,
      kind: StudyNodeKind.leaf,
      progress: StudyNodeProgress.available,
    );
    return (course: course, nodes: [node]);
  }

  /// Mark [doneId] done and unlock the next leaf in tree order.
  List<StudyNode> completeLeaf(List<StudyNode> all, String doneId) {
    final nodes = [...all];
    // Stable DFS order by parent groups.
    final ordered = leafOrder(nodes);
    final idx = ordered.indexWhere((n) => n.id == doneId);
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].id == doneId) {
        nodes[i] = nodes[i].copyWith(
          progress: StudyNodeProgress.done,
          mastery: nodes[i].mastery ?? StudyMastery.familiar,
        );
      }
    }
    if (idx >= 0 && idx + 1 < ordered.length) {
      final nextId = ordered[idx + 1].id;
      for (var i = 0; i < nodes.length; i++) {
        if (nodes[i].id == nextId &&
            nodes[i].progress == StudyNodeProgress.locked) {
          nodes[i] = nodes[i].copyWith(progress: StudyNodeProgress.available);
        }
      }
    }
    return nodes;
  }

  /// Leaves in the same stable depth-first order used for progression.
  List<StudyNode> leafOrder(List<StudyNode> nodes) {
    final byParent = <String?, List<StudyNode>>{};
    for (final n in nodes) {
      byParent.putIfAbsent(n.parentId, () => []).add(n);
    }
    for (final list in byParent.values) {
      list.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    }
    final out = <StudyNode>[];
    void walk(String? parentId) {
      for (final n in byParent[parentId] ?? const <StudyNode>[]) {
        if (n.kind == StudyNodeKind.leaf) {
          out.add(n);
        } else {
          walk(n.id);
        }
      }
    }

    walk(null);
    return out;
  }

  double progressRatio(List<StudyNode> nodes) {
    final leaves = nodes.where((n) => n.kind == StudyNodeKind.leaf).toList();
    if (leaves.isEmpty) return 0;
    final done = leaves
        .where((n) => n.progress == StudyNodeProgress.done)
        .length;
    return done / leaves.length;
  }
}
