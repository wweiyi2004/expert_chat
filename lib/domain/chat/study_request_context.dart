import 'package:characters/characters.dart';

import '../../data/models.dart';
import '../../data/study_models.dart';
import '../study/study_prompt_assembler.dart';
import '../study/tutor_style.dart';

/// Builds learning context from the loaded library, including legacy sessions.
abstract final class StudyRequestContext {
  static String build(Conversation convo, StudyLibrary library) {
    StudySessionMeta? session;
    for (final candidate in library.sessions) {
      if (candidate.conversationId != convo.id) continue;
      session = candidate;
      break;
    }
    // Compatibility fallback for a study conversation imported after the v10
    // migration marker was written. New sessions never use authorNote.
    if (session == null) {
      final legacy = StudyPromptAssembler.decodeSessionNote(convo.authorNote);
      if (legacy != null) {
        session = StudySessionMeta.fromJson({
          ...legacy,
          'conversationId': convo.id,
          'createdAt': convo.updatedAt.toIso8601String(),
        });
      }
    }
    final topic = session?.topic.trim().isNotEmpty == true
        ? session!.topic.trim()
        : convo.title.replaceFirst(RegExp(r'^学习[：:]'), '').trim();
    final style = session?.tutorStyle ?? TutorStyle.mixed;
    final courseId = session?.courseId;
    final nodeId = session?.nodeId;
    String? courseTitle;
    String? nodeTitle;
    var notes = '';
    if ((courseId ?? '').isNotEmpty || (nodeId ?? '').isNotEmpty) {
      if ((courseId ?? '').isNotEmpty) {
        for (final course in library.courses) {
          if (course.id != courseId) continue;
          courseTitle = course.title;
          notes = course.sourceSummary.trim();
          break;
        }
      }
      if ((nodeId ?? '').isNotEmpty) {
        for (final node in library.nodes) {
          if (node.id != nodeId) continue;
          nodeTitle = node.title;
          break;
        }
      }
    }
    if (notes.characters.length > 4000) {
      notes = '${notes.characters.take(4000)}…';
    }
    return const StudyPromptAssembler().tutorSystem(
      style: style,
      topic: topic.isEmpty ? '通用学习' : topic,
      courseTitle: courseTitle,
      nodeTitle: nodeTitle,
      notes: notes,
    );
  }
}
