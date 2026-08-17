import 'dart:convert';

import '../../data/study_models.dart';
import 'tutor_style.dart';

/// Builds system / one-shot prompts for study mode.
class StudyPromptAssembler {
  const StudyPromptAssembler();

  String tutorSystem({
    required TutorStyle style,
    required String topic,
    String? nodeTitle,
    String? courseTitle,
    String notes = '',
  }) {
    final buf = StringBuffer()
      ..writeln('你是 Expert Chat 的学习导师。当前为学习模式：以准确解释、引导理解和检查掌握为目标，不要写成娱乐角色扮演。')
      ..writeln('学习主题：$topic');
    if (courseTitle != null && courseTitle.trim().isNotEmpty) {
      buf.writeln('所属课程：${courseTitle.trim()}');
    }
    if (nodeTitle != null && nodeTitle.trim().isNotEmpty) {
      buf.writeln('当前知识点：${nodeTitle.trim()}');
    }
    if (notes.trim().isNotEmpty) {
      buf.writeln('补充材料（可能截断）：');
      buf.writeln(notes.trim());
    }
    buf.writeln();
    switch (style) {
      case TutorStyle.socratic:
        buf.writeln(
          '风格：苏格拉底式。优先用问题引导学生自己想；'
          '不要一次抛出完整答案。学生说「给提示」时给线索；说「完整讲解」时再系统讲解。',
        );
      case TutorStyle.feynman:
        buf.writeln(
          '风格：费曼技巧。用简单语言、类比讲清概念，然后请学生用自己的话复述；'
          '指出复述中的漏洞并纠正。',
        );
      case TutorStyle.mixed:
        buf.writeln(
          '风格：混合。先用简短要点讲解，再提问检查理解；'
          '学生卡住时先提示，再完整讲解。',
        );
    }
    buf.writeln(
      '成人文学、性学、性健康或 R18 作品可作为正常学习主题：'
      '用学术、临床、历史或文学批评视角直接而准确地讨论，不因成人题材自动回避；'
      '但不将学习回答转成以性唤起为目的露骨创作或色情角色扮演。',
    );
    buf.writeln('回答使用简洁中文 Markdown，一次不要灌输过多内容。');
    buf.writeln('默认不假设可以联网；只基于对话与材料作答，不伪造引文或来源。');
    buf.writeln(
      '最终讲解、问题和结论必须完整写在正常回答（content）中；'
      '不要把学习内容只放在思考/推理（reasoning）中。',
    );
    return buf.toString().trim();
  }

  String courseOutlineUserPrompt({
    required String topic,
    String material = '',
  }) {
    final buf = StringBuffer()
      ..writeln('请为以下学习主题生成课程知识点树 JSON（不要其它说明文字）。')
      ..writeln('主题：$topic');
    if (material.trim().isNotEmpty) {
      buf.writeln('参考材料（可能截断）：');
      buf.writeln(material.trim());
    }
    buf.writeln(
      '格式：{"title":"...","children":[{"title":"章","children":[{"title":"叶子知识点"}]}]}',
    );
    buf.writeln('要求：2～4 章，每章 2～5 个叶子；叶子是可学的具体知识点；总节点不超过 30。');
    return buf.toString();
  }

  String nodeExplainUserPrompt({
    required String courseTitle,
    required String nodeTitle,
    String material = '',
  }) {
    final buf = StringBuffer()
      ..writeln('请为课程「$courseTitle」的知识点「$nodeTitle」写一段精讲。')
      ..writeln('要求：中文 Markdown；含定义/直觉/一个例子/易错点；400～800 字。');
    if (material.trim().isNotEmpty) {
      buf.writeln('可参考材料：');
      buf.writeln(material.trim());
    }
    return buf.toString();
  }

  String quizGenerateUserPrompt({
    required String topic,
    int count = 5,
    String focus = '',
    Set<StudyQuizType>? types,
    int difficulty = 3,
  }) {
    final requestedTypes = types == null || types.isEmpty
        ? StudyQuizType.values
        : StudyQuizType.values.where(types.contains);
    final typeWires = requestedTypes.map((type) => type.wire).join(', ');
    final safeDifficulty = difficulty.clamp(1, 5);
    final buf = StringBuffer()
      ..writeln('请生成 $count 道学习测验题，只输出 JSON 数组，不要其它文字。')
      ..writeln('主题：$topic')
      ..writeln('只使用题型：$typeWires')
      ..writeln('目标难度：$safeDifficulty/5（允许上下浮动 1 级）');
    if (focus.trim().isNotEmpty) {
      buf.writeln('聚焦：$focus');
    }
    buf.writeln(
      '每项：{"type":"single|bool|cloze|short","stem":"题干",'
      '"options":["A选项","B选项"],"answer":"A 或 正确答案","explanation":"解析",'
      '"difficulty":1-5}',
    );
    buf.writeln(
      'single 为单选；bool 为判断（options 可用 ["正确","错误"]）；'
      'cloze 填空；short 简答。选择题必须有 options 与明确 answer。',
    );
    return buf.toString();
  }

  String gradeShortUserPrompt({
    required String stem,
    required String expected,
    required String userAnswer,
  }) {
    return '''
请批改简答题，只输出 JSON：
{"correct":true/false,"partial":true/false,"score":0到1,"explanation":"解析"}

题干：$stem
参考要点：$expected
学生答案：$userAnswer
''';
  }

  String summaryUserPrompt({required String transcript}) {
    return '''
根据以下学习对话，用中文列出 3～5 条要点小结（ bulleted Markdown）。
不要寒暄。

对话：
$transcript
''';
  }

  String cardsFromContextUserPrompt({
    required String topic,
    required String context,
    int count = 5,
  }) {
    return '''
根据主题「$topic」与下列内容，生成 $count 张复习卡片。
只输出 JSON 数组：[{"front":"问题","back":"答案","hint":"可选提示"}]

内容：
$context
''';
  }

  /// Encode session bootstrap into conversation.authorNote (JSON line).
  static String encodeSessionNote({
    required StudyPath path,
    required TutorStyle tutorStyle,
    required String topic,
    String? courseId,
    String? nodeId,
  }) {
    return 'study_meta:${jsonEncode({'path': path.wire, 'tutorStyle': tutorStyle.wire, 'topic': topic, 'courseId': ?courseId, 'nodeId': ?nodeId})}';
  }

  static Map<String, dynamic>? decodeSessionNote(String authorNote) {
    final line = authorNote
        .split('\n')
        .map((e) => e.trim())
        .firstWhere((e) => e.startsWith('study_meta:'), orElse: () => '');
    if (line.isEmpty) return null;
    final raw = line.substring('study_meta:'.length);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }
}
