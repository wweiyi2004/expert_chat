/// Tutor interaction style for study-mode sessions.
enum TutorStyle {
  socratic,
  feynman,
  mixed;

  String get wire => name;

  String get label => switch (this) {
    TutorStyle.socratic => '苏格拉底',
    TutorStyle.feynman => '费曼',
    TutorStyle.mixed => '混合',
  };

  String get shortHint => switch (this) {
    TutorStyle.socratic => '多追问，少直接给完整答案',
    TutorStyle.feynman => '用简单话讲清，再让你复述',
    TutorStyle.mixed => '先讲要点，再检查理解',
  };

  static TutorStyle fromWire(String? value) {
    for (final style in TutorStyle.values) {
      if (style.wire == value) return style;
    }
    return TutorStyle.mixed;
  }
}

/// Study path kind for hub routing and session meta.
enum StudyPath {
  tutor,
  course,
  quiz,
  review;

  String get wire => name;

  String get label => switch (this) {
    StudyPath.tutor => '导师',
    StudyPath.course => '课程',
    StudyPath.quiz => '刷题',
    StudyPath.review => '复习',
  };

  static StudyPath fromWire(String? value) {
    for (final path in StudyPath.values) {
      if (path.wire == value) return path;
    }
    return StudyPath.tutor;
  }
}
