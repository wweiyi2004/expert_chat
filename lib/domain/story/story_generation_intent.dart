/// The kind of work requested from the story model for this turn.
///
/// Keeping the intent explicit prevents planning or consultation requests from
/// being forced through the prose-writing prompt used by ordinary director
/// commands.
enum StoryGenerationIntent {
  /// A free-form direction that should be applied to story prose.
  directProse,

  /// Write the next unwritten outline beat as one complete scene.
  nextScene,

  /// Continue the most recently written scene without advancing the outline.
  continueScene,

  /// Rewrite prose according to the user's latest direction.
  rewrite,

  /// Revise or discuss the outline; do not emit story prose by default.
  revisePlan,

  /// Explicitly change established story canon.
  retcon,

  /// Answer the director as a writing assistant, not as the narrator.
  consult,
}

extension StoryGenerationIntentX on StoryGenerationIntent {
  bool get writesProse => switch (this) {
    StoryGenerationIntent.directProse ||
    StoryGenerationIntent.nextScene ||
    StoryGenerationIntent.continueScene ||
    StoryGenerationIntent.rewrite => true,
    StoryGenerationIntent.revisePlan ||
    StoryGenerationIntent.retcon ||
    StoryGenerationIntent.consult => false,
  };

  bool get usesSceneContext => switch (this) {
    StoryGenerationIntent.directProse ||
    StoryGenerationIntent.nextScene ||
    StoryGenerationIntent.continueScene ||
    StoryGenerationIntent.rewrite => true,
    StoryGenerationIntent.revisePlan ||
    StoryGenerationIntent.retcon ||
    StoryGenerationIntent.consult => false,
  };

  bool get advancesOutline => this == StoryGenerationIntent.nextScene;
}

/// Lightweight, deterministic routing for typed director commands.
///
/// Slash commands are unambiguous. A few natural-language prefixes cover the
/// common UI-free path without asking a model to classify the request first.
class StoryGenerationIntentResolver {
  const StoryGenerationIntentResolver._();

  static StoryGenerationIntent fromUserText(String text) {
    final value = text.trimLeft();
    if (_startsWithAny(value, const ['/咨询', '/问助手', '（导演：咨询）', '问导演助手'])) {
      return StoryGenerationIntent.consult;
    }
    if (_startsWithAny(value, const [
      '/改大纲',
      '/大纲',
      '（导演：调整大纲）',
      '调整大纲',
      '修改大纲',
    ])) {
      return StoryGenerationIntent.revisePlan;
    }
    if (_startsWithAny(value, const [
      '/改设定',
      '/重构设定',
      '（导演：改设定）',
      '改设定',
      '重构设定',
    ])) {
      return StoryGenerationIntent.retcon;
    }
    if (_startsWithAny(value, const ['/重写', '（导演：重写）', '重写上一段', '重写这段'])) {
      return StoryGenerationIntent.rewrite;
    }
    if (_startsWithAny(value, const ['（导演：续写当前场）', '（导演：续写本场）'])) {
      return StoryGenerationIntent.continueScene;
    }
    if (_startsWithAny(value, const [
      '（导演：写下一场）',
      '（导演：开始第一场）',
      '（导演：继续下一节）', // Legacy persisted cue.
      '（导演：开始第一节）', // Legacy persisted cue.
      '（推进情节）',
    ])) {
      return StoryGenerationIntent.nextScene;
    }
    return StoryGenerationIntent.directProse;
  }

  static bool _startsWithAny(String value, List<String> prefixes) =>
      prefixes.any(value.startsWith);
}
