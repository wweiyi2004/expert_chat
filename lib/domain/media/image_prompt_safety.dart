import '../../data/story_models.dart';

/// Builds and sanitizes text-to-image prompts.
///
/// Chat / story text may be R18; prompts sent to the image API for character
/// portraits (and dialogue auto-illustrations) must stay SFW.
class ImagePromptSafety {
  const ImagePromptSafety._();

  /// Hard tail appended to every dialogue / character image prompt.
  static const sfwSuffix =
      'safe for work, fully clothed, no nsfw, no sexual content, '
      'no nudity, no explicit anatomy';

  /// Portrait-oriented style hint for character-book sessions.
  static const characterStyleHint =
      'character portrait, upper body, clean design, illustrative, '
      'consistent character sheet style';

  /// Build a SFW character portrait prompt from a card.
  ///
  /// [userHint] may carry a short pose/expression wish; long story text and
  /// sexual content are stripped. Card [description] is the primary source.
  static String characterPortrait(
    CharacterCard card, {
    String? userHint,
  }) {
    final name = card.name.trim();
    final look = _sanitizeFragment(card.description, maxChars: 480);
    final vibe = _sanitizeFragment(card.personality, maxChars: 160);
    final hint = _sanitizeFragment(userHint ?? '', maxChars: 120);

    final parts = <String>[
      if (name.isNotEmpty) 'character named $name',
      if (look.isNotEmpty) look,
      if (vibe.isNotEmpty) 'demeanor: $vibe',
      if (hint.isNotEmpty) hint,
      characterStyleHint,
      sfwSuffix,
    ];
    return parts.join(', ');
  }

  /// Free-form dialogue illustration prompt (no character card).
  ///
  /// Scrubs NSFW phrasing from the model- or user-provided draft.
  static String freeform(String raw, {int maxChars = 800}) {
    final cleaned = _sanitizeFragment(raw, maxChars: maxChars);
    if (cleaned.isEmpty) {
      return 'simple wholesome illustration, $sfwSuffix';
    }
    return '$cleaned, $sfwSuffix';
  }

  /// Strip code fences / quotes then run NSFW scrub (shared with pure 生图
  /// deep-think cleanup callers that want an extra safety pass).
  static String scrub(String raw, {int maxChars = 800}) =>
      _sanitizeFragment(raw, maxChars: maxChars);

  static String _sanitizeFragment(String raw, {required int maxChars}) {
    var text = raw.trim();
    if (text.isEmpty) return '';

    final fence = RegExp(r'^```(?:\w+)?\s*([\s\S]*?)\s*```$');
    final m = fence.firstMatch(text);
    if (m != null) text = (m.group(1) ?? '').trim();

    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'")) ||
        (text.startsWith('“') && text.endsWith('”'))) {
      text = text.substring(1, text.length - 1).trim();
    }

    // Drop obvious R18 / explicit spans (CN + EN). Conservative: better to
    // lose a spicy adjective than to send it to the image model.
    text = text.replaceAll(_nsfwPattern, ' ');
    text = text.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    if (text.length <= maxChars) return text;
    // Prefer cutting on a separator so we don't end mid-word when possible.
    final cut = text.substring(0, maxChars);
    final lastSep = cut.lastIndexOf(RegExp(r'[,;，。；\s]'));
    if (lastSep > maxChars ~/ 2) return cut.substring(0, lastSep).trim();
    return cut.trim();
  }

  /// Broad SFW filter for portrait prompts. Not a full moderator — only keeps
  /// obvious sexual / explicit tokens out of the image request.
  /// Word-bounded English tokens so short stems (e.g. `sm` from SM) do not
  /// destroy innocent words like "smile".
  static final RegExp _nsfwPattern = RegExp(
    [
      // English (use \\b on short / ambiguous tokens)
      r'\bnsfw\b',
      r'\bporn\b',
      r'\bxxx\b',
      r'\bnude\b',
      r'\bnaked\b',
      r'\bnudity\b',
      r'bare\s*breasts?',
      r'\bbreasts?\b',
      r'\bnipples?\b',
      r'\bareola\b',
      r'\bgenital\w*\b',
      r'\bpenis\b',
      r'\bvagina\b',
      r'\banus\b',
      r'\banal\b',
      r'oral\s*sex',
      r'blow\s*jobs?',
      r'hand\s*jobs?',
      r'\bcum\b',
      r'\bsemen\b',
      r'\bejaculat\w*\b',
      r'\borgasm\b',
      r'\bmasturbat\w*\b',
      r'\berotic\b',
      r'\bsexual\b',
      r'\bsexy\b',
      r'\bsex\b',
      r'\bhentai\b',
      r'\bahegao\b',
      r'\becchi\b',
      r'\bloli\b',
      r'underage\s*sex',
      r'child\s*porn',
      r'only\s*fans',
      r'\blingerie\b',
      r'\bthong\b',
      r'\bpanties\b',
      r'bikini\s*bottom',
      r'see[\s-]*through',
      r'transparent\s*cloth\w*',
      r'no\s*clothes',
      r'without\s*clothes',
      r'\bundress\w*\b',
      r'\bstrip(?:ping|ped|tease)?\b',
      r'\bmissionary\b',
      r'\bdoggystyle\b',
      r'\bcowgirl\b',
      r'\bbdsm\b',
      r'\bbondage\b',
      r'\bfetish\b',
      r'\brape\b',
      r'\bmolest\w*\b',
      r'\bsm\b', // BDSM shorthand; word-bounded so "smile" survives
      // Chinese multi-char phrases (no Latin word-boundary issues)
      r'色情',
      r'情色',
      r'黄图',
      r'裸体',
      r'裸身',
      r'全裸',
      r'半裸',
      r'裸露',
      r'裸(?:体|奔|照)',
      r'脱光',
      r'脱衣',
      r'无码',
      r'有码',
      r'做爱',
      r'性爱',
      r'性交',
      r'交媾',
      r'房事',
      r'啪啪',
      r'上床',
      r'床戏',
      r'爱爱',
      r'自慰',
      r'手淫',
      r'射精',
      r'高潮',
      r'呻吟',
      r'娇喘',
      r'舔弄',
      r'口交',
      r'肛交',
      r'内射',
      r'外射',
      r'中出',
      r'颜射',
      r'肉棒',
      r'鸡巴',
      r'阴茎',
      r'阴道',
      r'阴蒂',
      r'乳头',
      r'乳房',
      r'奶子',
      r'巨乳',
      r'贫乳',
      r'翘臀',
      r'蜜穴',
      r'小穴',
      r'私处',
      r'下体',
      r'性器',
      r'敏感点',
      r'调教',
      r'捆绑',
      r'里番',
      r'工口',
      r'涩图',
      r'衣不蔽体',
      r'透视装',
      r'情趣内衣',
      r'开档',
      r'淫(?:荡|乱|靡|叫|语|水|纹)',
      r'迷奸',
      r'轮奸',
      r'强奸',
    ].join('|'),
    caseSensitive: false,
  );
}
