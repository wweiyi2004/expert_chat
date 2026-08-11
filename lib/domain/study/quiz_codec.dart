import 'dart:convert';

import '../../data/study_models.dart';

/// Parse / grade study quiz items from model JSON or plain structures.
class QuizCodec {
  const QuizCodec();

  /// Extract a JSON array or object from model text (markdown fences ok).
  static String? extractJsonBlob(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final fence = RegExp(
      r'```(?:json)?\s*([\s\S]*?)```',
      caseSensitive: false,
    ).firstMatch(text);
    final candidate = fence != null ? fence.group(1)!.trim() : text;
    final startArr = candidate.indexOf('[');
    final startObj = candidate.indexOf('{');
    if (startArr < 0 && startObj < 0) return null;
    if (startArr >= 0 && (startObj < 0 || startArr < startObj)) {
      final end = candidate.lastIndexOf(']');
      if (end > startArr) return candidate.substring(startArr, end + 1);
    }
    final end = candidate.lastIndexOf('}');
    if (startObj >= 0 && end > startObj) {
      return candidate.substring(startObj, end + 1);
    }
    return null;
  }

  List<StudyQuizItem> parseItems(
    String raw, {
    String? courseId,
    String? nodeId,
  }) {
    final blob = extractJsonBlob(raw);
    if (blob == null) return const [];
    final decoded = jsonDecode(blob);
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['items'] is List)
        ? decoded['items'] as List
        : const [];
    final out = <StudyQuizItem>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final item = StudyQuizItem.fromModelMap(
        map,
        courseId: courseId,
        nodeId: nodeId,
      );
      if (item != null) out.add(item);
    }
    return out;
  }

  List<StudyCard> parseCards(String raw, {String? courseId, String? nodeId}) {
    final blob = extractJsonBlob(raw);
    if (blob == null) return const [];
    final decoded = jsonDecode(blob);
    final list = decoded is List
        ? decoded
        : (decoded is Map && decoded['cards'] is List)
        ? decoded['cards'] as List
        : const [];
    final out = <StudyCard>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final map = Map<String, dynamic>.from(entry);
      final front = (map['front'] ?? map['q'] ?? map['question'] ?? '')
          .toString()
          .trim();
      final back = (map['back'] ?? map['a'] ?? map['answer'] ?? '')
          .toString()
          .trim();
      if (front.isEmpty || back.isEmpty) continue;
      out.add(
        StudyCard(
          front: front,
          back: back,
          hint: (map['hint'] ?? '').toString(),
          courseId: courseId,
          nodeId: nodeId,
        ),
      );
    }
    return out;
  }

  /// Local grade for objective items. Short/cloze return null (need model).
  QuizGrade? gradeLocal(StudyQuizItem item, String userAnswer) {
    final answer = userAnswer.trim();
    switch (item.type) {
      case StudyQuizType.single:
        final key = item.answerKey.trim().toLowerCase();
        final got = answer.toLowerCase();
        final ok =
            got == key ||
            got == item.answerText.trim().toLowerCase() ||
            _optionMatches(item, answer);
        return QuizGrade(
          correct: ok,
          partial: false,
          explanation: item.explanation,
          score: ok ? 1 : 0,
        );
      case StudyQuizType.boolType:
        final expected =
            _booleanValue(item.answerText) ?? _booleanValue(item.answerKey);
        var selected = _booleanValue(answer);
        final optionIndex = _optionIndex(answer, item.options.length);
        if (selected == null && optionIndex != null) {
          selected = _booleanValue(item.options[optionIndex]);
        }
        final ok = expected != null && selected == expected;
        return QuizGrade(
          correct: ok,
          partial: false,
          explanation: item.explanation,
          score: ok ? 1 : 0,
        );
      case StudyQuizType.cloze:
      case StudyQuizType.short:
        return null;
    }
  }

  bool _optionMatches(StudyQuizItem item, String userAnswer) {
    final u = userAnswer.trim().toLowerCase();
    for (var i = 0; i < item.options.length; i++) {
      final label = String.fromCharCode(65 + i); // A, B, C…
      final opt = item.options[i].trim().toLowerCase();
      if (u == label.toLowerCase() || u == opt) {
        return label.toLowerCase() == item.answerKey.trim().toLowerCase() ||
            opt == item.answerText.trim().toLowerCase() ||
            label.toLowerCase() == item.answerText.trim().toLowerCase();
      }
    }
    return false;
  }

  int? _optionIndex(String answer, int optionCount) {
    final normalized = answer.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]$').hasMatch(normalized)) return null;
    final index = normalized.codeUnitAt(0) - 65;
    return index >= 0 && index < optionCount ? index : null;
  }

  bool? _booleanValue(String value) {
    return switch (value.trim().toLowerCase()) {
      'true' || '1' || 'yes' || 'y' || '正确' || '对' || '是' => true,
      'false' || '0' || 'no' || 'n' || '错误' || '错' || '否' => false,
      _ => null,
    };
  }

  QuizGrade? parseGrade(String raw) {
    final blob = extractJsonBlob(raw);
    if (blob == null) return null;
    try {
      final map = jsonDecode(blob);
      if (map is! Map) return null;
      final m = Map<String, dynamic>.from(map);
      final correct = m['correct'] == true || m['correct'] == 'true';
      final partial = m['partial'] == true || m['partial'] == 'true';
      final score = (m['score'] is num)
          ? (m['score'] as num).toDouble()
          : (correct ? 1.0 : (partial ? 0.5 : 0.0));
      return QuizGrade(
        correct: correct,
        partial: partial,
        explanation: (m['explanation'] ?? m['解析'] ?? '').toString(),
        score: score,
      );
    } catch (_) {
      return null;
    }
  }
}

class QuizGrade {
  const QuizGrade({
    required this.correct,
    required this.partial,
    required this.explanation,
    required this.score,
  });

  final bool correct;
  final bool partial;
  final String explanation;
  final double score;
}
