/// Compiles the three persistent sources used by director stories into one
/// canonical, de-duplicated note stored on the conversation.
class StoryConstraintCompiler {
  const StoryConstraintCompiler._();

  static String compile({
    required String premise,
    String requirements = '',
    String persistentNote = '',
  }) {
    final sections = <String>[];
    final seen = <String>{};

    void add(String header, String value) {
      final body = value.trim();
      if (body.isEmpty) return;
      final normalized = body.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      if (!seen.add(normalized)) return;
      sections.add('$header\n$body');
    }

    // Requirements may already contain typed sub-headings produced by the
    // prose-style compiler, so do not wrap them in another "all hard" block.
    add('【创作约束】', requirements);
    add('【长期导演备注】', persistentNote);
    add('【故事基准】', premise);
    return sections.join('\n\n');
  }
}
