/// User-facing appearance / reading preferences (persisted in settings).
enum TextScalePref {
  extraSmall,
  small,
  medium,
  large,
  extraLarge;

  String get label => switch (this) {
    TextScalePref.extraSmall => '更小',
    TextScalePref.small => '小',
    TextScalePref.medium => '中',
    TextScalePref.large => '大',
    TextScalePref.extraLarge => '更大',
  };

  double get scale => switch (this) {
    TextScalePref.extraSmall => 0.82,
    TextScalePref.small => 0.9,
    TextScalePref.medium => 1.0,
    TextScalePref.large => 1.12,
    TextScalePref.extraLarge => 1.24,
  };

  String get wire => name;

  static TextScalePref fromWire(String? v) => TextScalePref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => TextScalePref.medium,
  );
}

enum DensityPref {
  spacious,
  comfortable,
  compact;

  String get label => switch (this) {
    DensityPref.spacious => '宽松',
    DensityPref.comfortable => '舒适',
    DensityPref.compact => '紧凑',
  };

  VisualDensityKind get visualDensityKind => switch (this) {
    DensityPref.spacious => VisualDensityKind.comfortable,
    DensityPref.comfortable => VisualDensityKind.standard,
    DensityPref.compact => VisualDensityKind.compact,
  };

  String get wire => name;

  static DensityPref fromWire(String? v) => DensityPref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => DensityPref.comfortable,
  );
}

/// Maps to Flutter [VisualDensity] without importing material in this file.
enum VisualDensityKind { comfortable, standard, compact }

enum MessageStylePref {
  bubble,
  document;

  String get label => switch (this) {
    MessageStylePref.bubble => '气泡',
    MessageStylePref.document => '文档',
  };

  String get wire => name;

  static MessageStylePref fromWire(String? v) => MessageStylePref.values
      .firstWhere((e) => e.name == v, orElse: () => MessageStylePref.bubble);
}

/// Visual skin for assistant Markdown (not just type scale).
enum MarkdownStylePref {
  standard,
  github,
  notion,
  terminal;

  String get label => switch (this) {
    MarkdownStylePref.standard => '聊天',
    MarkdownStylePref.github => 'GitHub',
    MarkdownStylePref.notion => '笔记',
    MarkdownStylePref.terminal => '终端',
  };

  String get description => switch (this) {
    MarkdownStylePref.standard => '默认聊天渲染：标题适中，代码块跟随主题。',
    MarkdownStylePref.github => '文档站风格：行内代码灰底、表头底纹、标题下划线。',
    MarkdownStylePref.notion => '笔记风格：柔和标题、红色行内代码、轻量表格。',
    MarkdownStylePref.terminal => '终端风格：更密正文、深色代码、绿色行内代码。',
  };

  String get wire => name;

  static MarkdownStylePref fromWire(String? v) => switch (v) {
    'github' => MarkdownStylePref.github,
    'notion' || 'article' => MarkdownStylePref.notion,
    'terminal' || 'compact' => MarkdownStylePref.terminal,
    _ => MarkdownStylePref.standard,
  };
}

enum ContentWidthPref {
  narrow,
  regular,
  wide,
  full;

  String get label => switch (this) {
    ContentWidthPref.narrow => '窄',
    ContentWidthPref.regular => '标准',
    ContentWidthPref.wide => '宽',
    ContentWidthPref.full => '铺满',
  };

  /// Max width of the message column (phone ignores — full width).
  double get maxWidth => switch (this) {
    ContentWidthPref.narrow => 640,
    ContentWidthPref.regular => 800,
    ContentWidthPref.wide => 1100,
    ContentWidthPref.full => 10000,
  };

  String get wire => name;

  static ContentWidthPref fromWire(String? v) => ContentWidthPref.values
      .firstWhere((e) => e.name == v, orElse: () => ContentWidthPref.regular);
}

/// Curated app color palettes (seed + accent personality).
///
/// Sources of inspiration (not 1:1 brand copies):
/// Material 3 tonal systems, Apple HIG system colors, Nord, GitHub Primer,
/// Stripe indigo, Solarized (Ethan Schoonover), warm editorial clay.
enum ColorThemePref {
  inkTeal,
  ocean,
  forest,
  rose,
  violet,
  amber,
  slate,
  nord,
  primer,
  stripe,
  graphite,
  clay,
  solar;

  String get label => switch (this) {
    ColorThemePref.inkTeal => '墨青',
    ColorThemePref.ocean => '海雾',
    ColorThemePref.forest => '松绿',
    ColorThemePref.rose => '玫瑰',
    ColorThemePref.violet => '暮紫',
    ColorThemePref.amber => '琥珀',
    ColorThemePref.slate => '石板',
    ColorThemePref.nord => '极光',
    ColorThemePref.primer => 'Primer',
    ColorThemePref.stripe => '靛紫',
    ColorThemePref.graphite => '石墨',
    ColorThemePref.clay => '陶土',
    ColorThemePref.solar => '日辉',
  };

  String get description => switch (this) {
    ColorThemePref.inkTeal => '冷静编辑台',
    ColorThemePref.ocean => '清爽信息蓝',
    ColorThemePref.forest => '自然阅读绿',
    ColorThemePref.rose => '柔和暖粉',
    ColorThemePref.violet => '文艺创作紫',
    ColorThemePref.amber => '暖意专注',
    ColorThemePref.slate => '低饱和中性',
    ColorThemePref.nord => '北极冷灰蓝',
    ColorThemePref.primer => '专业工程蓝',
    ColorThemePref.stripe => '现代靛紫',
    ColorThemePref.graphite => '系统石墨蓝',
    ColorThemePref.clay => '人文陶土',
    ColorThemePref.solar => '护眼日辉',
  };

  /// Preview swatch for settings chips (light-mode primary-ish).
  int get previewArgb => switch (this) {
    ColorThemePref.inkTeal => 0xFF1F5C6B,
    ColorThemePref.ocean => 0xFF2B6CB0,
    ColorThemePref.forest => 0xFF2F6B4F,
    ColorThemePref.rose => 0xFFB04A6E,
    ColorThemePref.violet => 0xFF6B5B95,
    ColorThemePref.amber => 0xFFB7791F,
    ColorThemePref.slate => 0xFF4A5568,
    ColorThemePref.nord => 0xFF5E81AC,
    ColorThemePref.primer => 0xFF0969DA,
    ColorThemePref.stripe => 0xFF635BFF,
    ColorThemePref.graphite => 0xFF007AFF,
    ColorThemePref.clay => 0xFFC15F3C,
    ColorThemePref.solar => 0xFF268BD2,
  };

  /// Secondary preview (accent) for dual-tone swatches.
  int get accentPreviewArgb => switch (this) {
    ColorThemePref.inkTeal => 0xFFC45C26,
    ColorThemePref.ocean => 0xFF0D9488,
    ColorThemePref.forest => 0xFFB45309,
    ColorThemePref.rose => 0xFF7C3AED,
    ColorThemePref.violet => 0xFFDB2777,
    ColorThemePref.amber => 0xFF0F766E,
    ColorThemePref.slate => 0xFF64748B,
    ColorThemePref.nord => 0xFF88C0D0,
    ColorThemePref.primer => 0xFF1A7F37,
    ColorThemePref.stripe => 0xFF0A2540,
    ColorThemePref.graphite => 0xFF5856D6,
    ColorThemePref.clay => 0xFF5C4033,
    ColorThemePref.solar => 0xFFB58900,
  };

  String get wire => name;

  static ColorThemePref fromWire(String? v) => ColorThemePref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => ColorThemePref.inkTeal,
  );
}

enum CornerStylePref {
  sharp,
  medium,
  soft;

  String get label => switch (this) {
    CornerStylePref.sharp => '直角',
    CornerStylePref.medium => '适中',
    CornerStylePref.soft => '圆润',
  };

  /// Base radius used across cards / inputs / chips.
  double get radiusMd => switch (this) {
    CornerStylePref.sharp => 8,
    CornerStylePref.medium => 14,
    CornerStylePref.soft => 20,
  };

  double get radiusLg => radiusMd + 4;

  double get bubbleMain => switch (this) {
    CornerStylePref.sharp => 10,
    CornerStylePref.medium => 20,
    CornerStylePref.soft => 26,
  };

  double get bubbleTail => switch (this) {
    CornerStylePref.sharp => 4,
    CornerStylePref.medium => 6,
    CornerStylePref.soft => 10,
  };

  String get wire => name;

  static CornerStylePref fromWire(String? v) => CornerStylePref.values
      .firstWhere((e) => e.name == v, orElse: () => CornerStylePref.medium);
}

enum ChatSurfacePref {
  plain,
  paper,
  tinted;

  String get label => switch (this) {
    ChatSurfacePref.plain => '纯色',
    ChatSurfacePref.paper => '纸感',
    ChatSurfacePref.tinted => '淡彩',
  };

  String get description => switch (this) {
    ChatSurfacePref.plain => '干净单色底',
    ChatSurfacePref.paper => '轻微纹理感渐变',
    ChatSurfacePref.tinted => '主色淡染背景',
  };

  String get wire => name;

  static ChatSurfacePref fromWire(String? v) => ChatSurfacePref.values
      .firstWhere((e) => e.name == v, orElse: () => ChatSurfacePref.plain);
}

/// Read-aloud speed passed to the configured cloud TTS service. OpenAI-style
/// endpoints receive a `speed` field; MiMo receives the requested pace in its
/// speech-style instruction.
enum TtsSpeedPref {
  slow,
  normal,
  fast;

  String get label => switch (this) {
    TtsSpeedPref.slow => '慢',
    TtsSpeedPref.normal => '正常',
    TtsSpeedPref.fast => '快',
  };

  double get speechRate => switch (this) {
    TtsSpeedPref.slow => 0.38,
    TtsSpeedPref.normal => 0.5,
    TtsSpeedPref.fast => 0.62,
  };

  String get wire => name;

  static TtsSpeedPref fromWire(String? v) => TtsSpeedPref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => TtsSpeedPref.normal,
  );
}

class UiPrefs {
  const UiPrefs({
    this.textScale = TextScalePref.medium,
    this.density = DensityPref.comfortable,
    this.messageStyle = MessageStylePref.bubble,
    this.markdownStyle = MarkdownStylePref.standard,
    this.contentWidth = ContentWidthPref.regular,
    this.colorTheme = ColorThemePref.inkTeal,
    this.cornerStyle = CornerStylePref.medium,
    this.chatSurface = ChatSurfacePref.plain,
    this.liveMarkdown = true,
    this.ttsSpeed = TtsSpeedPref.normal,
    this.ttsAutoEmotion = true,
    this.ttsVoicePackId = '',
  });

  final TextScalePref textScale;
  final DensityPref density;
  final MessageStylePref messageStyle;
  final MarkdownStylePref markdownStyle;
  final ContentWidthPref contentWidth;
  final ColorThemePref colorTheme;
  final CornerStylePref cornerStyle;
  final ChatSurfacePref chatSurface;

  /// When true, stream assistant replies as live Markdown (not plain text).
  final bool liveMarkdown;

  /// Read-aloud speed, independent from visual text size.
  final TtsSpeedPref ttsSpeed;

  /// When true, each TTS sentence gets an auto-inferred emotion / delivery
  /// instruction so long replies sound more expressive and context-aware.
  final bool ttsAutoEmotion;

  /// Selected custom TTS voice pack id, or empty for "use TTS card settings".
  final String ttsVoicePackId;

  UiPrefs copyWith({
    TextScalePref? textScale,
    DensityPref? density,
    MessageStylePref? messageStyle,
    MarkdownStylePref? markdownStyle,
    ContentWidthPref? contentWidth,
    ColorThemePref? colorTheme,
    CornerStylePref? cornerStyle,
    ChatSurfacePref? chatSurface,
    bool? liveMarkdown,
    TtsSpeedPref? ttsSpeed,
    bool? ttsAutoEmotion,
    String? ttsVoicePackId,
  }) => UiPrefs(
    textScale: textScale ?? this.textScale,
    density: density ?? this.density,
    messageStyle: messageStyle ?? this.messageStyle,
    markdownStyle: markdownStyle ?? this.markdownStyle,
    contentWidth: contentWidth ?? this.contentWidth,
    colorTheme: colorTheme ?? this.colorTheme,
    cornerStyle: cornerStyle ?? this.cornerStyle,
    chatSurface: chatSurface ?? this.chatSurface,
    liveMarkdown: liveMarkdown ?? this.liveMarkdown,
    ttsSpeed: ttsSpeed ?? this.ttsSpeed,
    ttsAutoEmotion: ttsAutoEmotion ?? this.ttsAutoEmotion,
    ttsVoicePackId: ttsVoicePackId ?? this.ttsVoicePackId,
  );

  Map<String, dynamic> toJson() => {
    'textScale': textScale.wire,
    'density': density.wire,
    'messageStyle': messageStyle.wire,
    'markdownStyle': markdownStyle.wire,
    'contentWidth': contentWidth.wire,
    'colorTheme': colorTheme.wire,
    'cornerStyle': cornerStyle.wire,
    'chatSurface': chatSurface.wire,
    'liveMarkdown': liveMarkdown,
    'ttsSpeed': ttsSpeed.wire,
    'ttsAutoEmotion': ttsAutoEmotion,
    'ttsVoicePackId': ttsVoicePackId,
  };

  factory UiPrefs.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UiPrefs();
    // Resolve each field with a type check so a single corrupt entry falls
    // back to its own default instead of throwing and resetting every pref
    // (which the settings layer would then persist over the healthy ones).
    String? str(String key) => json[key] is String ? json[key] as String : null;
    bool? flag(String key) => json[key] is bool ? json[key] as bool : null;
    return UiPrefs(
      textScale: TextScalePref.fromWire(str('textScale')),
      density: DensityPref.fromWire(str('density')),
      messageStyle: MessageStylePref.fromWire(str('messageStyle')),
      markdownStyle: MarkdownStylePref.fromWire(str('markdownStyle')),
      contentWidth: ContentWidthPref.fromWire(str('contentWidth')),
      colorTheme: ColorThemePref.fromWire(str('colorTheme')),
      cornerStyle: CornerStylePref.fromWire(str('cornerStyle')),
      chatSurface: ChatSurfacePref.fromWire(str('chatSurface')),
      liveMarkdown: flag('liveMarkdown') ?? true,
      ttsSpeed: TtsSpeedPref.fromWire(str('ttsSpeed')),
      ttsAutoEmotion: flag('ttsAutoEmotion') ?? true,
      ttsVoicePackId: str('ttsVoicePackId') ?? '',
    );
  }
}
