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
    ContentWidthPref.regular => 700,
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
  minimal,
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
  solar,
  dailan,
  yanzhi,
  zhuqing,
  jiangzi,
  wadaSienna,
  wadaSulphur,
  wadaCossack,
  wadaViolet;

  String get label => switch (this) {
    ColorThemePref.minimal => '极简',
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
    ColorThemePref.dailan => '黛蓝·月白',
    ColorThemePref.yanzhi => '胭脂·象牙',
    ColorThemePref.zhuqing => '竹青·缟素',
    ColorThemePref.jiangzi => '绛紫·藕荷',
    ColorThemePref.wadaSienna => '赭石·石板',
    ColorThemePref.wadaSulphur => '深海·硫黄',
    ColorThemePref.wadaCossack => '哥萨克绿',
    ColorThemePref.wadaViolet => '紫罗兰·尼罗蓝',
  };

  String get description => switch (this) {
    ColorThemePref.minimal => '白底黑字',
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
    ColorThemePref.dailan => '靛青墨蓝',
    ColorThemePref.yanzhi => '胭脂象牙',
    ColorThemePref.zhuqing => '竹青素纸',
    ColorThemePref.jiangzi => '绛紫藕荷',
    ColorThemePref.wadaSienna => '赭石石板',
    ColorThemePref.wadaSulphur => '深海硫黄',
    ColorThemePref.wadaCossack => '橄榄苔绿',
    ColorThemePref.wadaViolet => '紫罗兰青',
  };

  /// Preview swatch for settings chips (light-mode primary-ish).
  int get previewArgb => switch (this) {
    ColorThemePref.minimal => 0xFF4D6BFE,
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
    ColorThemePref.dailan => 0xFF1179AD,
    ColorThemePref.yanzhi => 0xFF9C2A33,
    ColorThemePref.zhuqing => 0xFF627B4C,
    ColorThemePref.jiangzi => 0xFF8C4356,
    ColorThemePref.wadaSienna => 0xFFAE5224,
    ColorThemePref.wadaSulphur => 0xFF064F6E,
    ColorThemePref.wadaCossack => 0xFF437742,
    ColorThemePref.wadaViolet => 0xFF6450A1,
  };

  /// Secondary preview (accent) for dual-tone swatches.
  int get accentPreviewArgb => switch (this) {
    ColorThemePref.minimal => 0xFF111827,
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
    ColorThemePref.dailan => 0xFF617581,
    ColorThemePref.yanzhi => 0xFF876C75,
    ColorThemePref.zhuqing => 0xFF61776E,
    ColorThemePref.jiangzi => 0xFF88639D,
    ColorThemePref.wadaSienna => 0xFF9C6734,
    ColorThemePref.wadaSulphur => 0xFFA2640C,
    ColorThemePref.wadaCossack => 0xFF60738D,
    ColorThemePref.wadaViolet => 0xFF00807A,
  };

  bool get isArt => index >= ColorThemePref.dailan.index;
  String get source => switch (this) {
    ColorThemePref.dailan ||
    ColorThemePref.yanzhi ||
    ColorThemePref.zhuqing ||
    ColorThemePref.jiangzi => '中国传统色',
    ColorThemePref.wadaSienna => '和田三造 · 组合 263',
    ColorThemePref.wadaSulphur => '和田三造 · 组合 151',
    ColorThemePref.wadaCossack => '和田三造 · 组合 135',
    ColorThemePref.wadaViolet => '和田三造 · 组合 345',
    _ => '原有配色',
  };
  List<int> get sourceColors => switch (this) {
    ColorThemePref.dailan => const [0xFF177CB0, 0xFFD6ECF0, 0xFF425066],
    ColorThemePref.yanzhi => const [0xFF9D2933, 0xFFFFFBF0, 0xFF4C221B],
    ColorThemePref.zhuqing => const [0xFF789262, 0xFFF2ECDE, 0xFF424C50],
    ColorThemePref.jiangzi => const [0xFF8C4356, 0xFFE4C6D0, 0xFF4A4266],
    ColorThemePref.wadaSienna => const [
      0xFFAE5224,
      0xFFB5DECC,
      0xFF34454C,
      0xFFEEB480,
    ],
    ColorThemePref.wadaSulphur => const [0xFF064F6E, 0xFFF5ECC2, 0xFFF99D1B],
    ColorThemePref.wadaCossack => const [0xFF437742, 0xFFF5ECC2, 0xFF97ACC8],
    ColorThemePref.wadaViolet => const [
      0xFF6450A1,
      0xFFBCE4E5,
      0xFF793327,
      0xFF62C6BF,
    ],
    _ => [previewArgb, 0xFFF7F7F8, accentPreviewArgb],
  };

  String get wire => name;

  static ColorThemePref fromWire(String? v) => ColorThemePref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => ColorThemePref.minimal,
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
    this.workbenchWidth = 560,
    this.sidebarCollapsedGroups = const [],
    this.textScale = TextScalePref.medium,
    this.density = DensityPref.comfortable,
    this.messageStyle = MessageStylePref.bubble,
    this.markdownStyle = MarkdownStylePref.standard,
    this.contentWidth = ContentWidthPref.regular,
    this.workContentWidth = ContentWidthPref.regular,
    this.workMessageStyle = MessageStylePref.document,
    this.lineHeight = 1.7,
    this.paragraphSpacing = 8,
    this.messageSpacing = 14,
    this.adaptiveMessagePadding = true,
    this.messagePadding = 20,
    this.popoverMaxHeight = 420,
    this.popoverTopMargin = 40,
    this.colorTheme = ColorThemePref.minimal,
    this.cornerStyle = CornerStylePref.medium,
    this.chatSurface = ChatSurfacePref.plain,
    this.liveMarkdown = true,
    this.ttsSpeed = TtsSpeedPref.normal,
    this.ttsAutoEmotion = true,
    this.ttsVoicePackId = '',
  });

  final double workbenchWidth;
  final List<String> sidebarCollapsedGroups;
  final TextScalePref textScale;
  final DensityPref density;
  final MessageStylePref messageStyle;
  final MarkdownStylePref markdownStyle;
  final ContentWidthPref contentWidth;
  final ContentWidthPref workContentWidth;
  final MessageStylePref workMessageStyle;
  final double lineHeight, paragraphSpacing, messageSpacing, messagePadding;
  final double popoverMaxHeight, popoverTopMargin;
  final bool adaptiveMessagePadding;

  double horizontalMessagePadding(double width, {bool? compact}) =>
      adaptiveMessagePadding
      ? ((compact ?? width < 480) ? 14 : 20)
      : messagePadding.clamp(12.0, width < 480 ? 24.0 : 72.0);
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
    double? workbenchWidth,
    List<String>? sidebarCollapsedGroups,
    TextScalePref? textScale,
    DensityPref? density,
    MessageStylePref? messageStyle,
    MarkdownStylePref? markdownStyle,
    ContentWidthPref? contentWidth,
    ContentWidthPref? workContentWidth,
    MessageStylePref? workMessageStyle,
    double? lineHeight,
    double? paragraphSpacing,
    double? messageSpacing,
    double? messagePadding,
    double? popoverMaxHeight,
    double? popoverTopMargin,
    bool? adaptiveMessagePadding,
    ColorThemePref? colorTheme,
    CornerStylePref? cornerStyle,
    ChatSurfacePref? chatSurface,
    bool? liveMarkdown,
    TtsSpeedPref? ttsSpeed,
    bool? ttsAutoEmotion,
    String? ttsVoicePackId,
  }) => UiPrefs(
    workbenchWidth: workbenchWidth == null
        ? this.workbenchWidth
        : (workbenchWidth.isFinite ? workbenchWidth.clamp(340.0, 900.0) : 560),
    sidebarCollapsedGroups: sidebarCollapsedGroups == null
        ? this.sidebarCollapsedGroups
        : List<String>.unmodifiable(sidebarCollapsedGroups.toSet().take(1000)),
    textScale: textScale ?? this.textScale,
    density: density ?? this.density,
    messageStyle: messageStyle ?? this.messageStyle,
    markdownStyle: markdownStyle ?? this.markdownStyle,
    contentWidth: contentWidth ?? this.contentWidth,
    workContentWidth: workContentWidth ?? this.workContentWidth,
    workMessageStyle: workMessageStyle ?? this.workMessageStyle,
    lineHeight: lineHeight ?? this.lineHeight,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    messageSpacing: messageSpacing ?? this.messageSpacing,
    messagePadding: messagePadding ?? this.messagePadding,
    adaptiveMessagePadding:
        adaptiveMessagePadding ?? this.adaptiveMessagePadding,
    popoverMaxHeight: popoverMaxHeight ?? this.popoverMaxHeight,
    popoverTopMargin: popoverTopMargin ?? this.popoverTopMargin,
    colorTheme: colorTheme ?? this.colorTheme,
    cornerStyle: cornerStyle ?? this.cornerStyle,
    chatSurface: chatSurface ?? this.chatSurface,
    liveMarkdown: liveMarkdown ?? this.liveMarkdown,
    ttsSpeed: ttsSpeed ?? this.ttsSpeed,
    ttsAutoEmotion: ttsAutoEmotion ?? this.ttsAutoEmotion,
    ttsVoicePackId: ttsVoicePackId ?? this.ttsVoicePackId,
  );

  Map<String, dynamic> toJson() => {
    'workbenchWidth': workbenchWidth,
    'sidebarCollapsedGroups': List<String>.of(sidebarCollapsedGroups),
    'textScale': textScale.wire,
    'density': density.wire,
    'messageStyle': messageStyle.wire,
    'markdownStyle': markdownStyle.wire,
    'contentWidth': contentWidth.wire,
    'workContentWidth': workContentWidth.wire,
    'workMessageStyle': workMessageStyle.wire,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'messageSpacing': messageSpacing,
    'messagePadding': messagePadding,
    'adaptiveMessagePadding': adaptiveMessagePadding,
    'popoverMaxHeight': popoverMaxHeight,
    'popoverTopMargin': popoverTopMargin,
    'colorTheme': colorTheme.wire,
    'styleVersion': currentStyleVersion,
    'cornerStyle': cornerStyle.wire,
    'chatSurface': chatSurface.wire,
    'liveMarkdown': liveMarkdown,
    'ttsSpeed': ttsSpeed.wire,
    'ttsAutoEmotion': ttsAutoEmotion,
    'ttsVoicePackId': ttsVoicePackId,
  };

  /// Bumped when a redesign changes defaults that older saves still carry.
  static const int currentStyleVersion = 2;

  /// Saves from before the 2026-09 redesign stored the old default palette;
  /// move them to the new one once. A later explicit choice is kept.
  static ColorThemePref _migrateColorTheme(
    ColorThemePref saved,
    Object? version,
  ) {
    final old = version is! int || version < currentStyleVersion;
    return old && saved == ColorThemePref.inkTeal
        ? ColorThemePref.minimal
        : saved;
  }

  factory UiPrefs.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UiPrefs();
    // Resolve each field with a type check so a single corrupt entry falls
    // back to its own default instead of throwing and resetting every pref
    // (which the settings layer would then persist over the healthy ones).
    String? str(String key) => json[key] is String ? json[key] as String : null;
    bool? flag(String key) => json[key] is bool ? json[key] as bool : null;
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    return UiPrefs(
      workbenchWidth: number('workbenchWidth', 560, 340, 900),
      sidebarCollapsedGroups: json['sidebarCollapsedGroups'] is List
          ? List<String>.unmodifiable(
              (json['sidebarCollapsedGroups'] as List)
                  .whereType<String>()
                  .toSet()
                  .take(1000),
            )
          : const [],
      textScale: TextScalePref.fromWire(str('textScale')),
      density: DensityPref.fromWire(str('density')),
      messageStyle: MessageStylePref.fromWire(str('messageStyle')),
      markdownStyle: MarkdownStylePref.fromWire(str('markdownStyle')),
      contentWidth: ContentWidthPref.fromWire(str('contentWidth')),
      workContentWidth: str('workContentWidth') == null
          ? ContentWidthPref.full
          : ContentWidthPref.fromWire(str('workContentWidth')),
      workMessageStyle: str('workMessageStyle') == null
          ? MessageStylePref.document
          : MessageStylePref.fromWire(str('workMessageStyle')),
      lineHeight: number('lineHeight', 1.85, 1.2, 2.4),
      paragraphSpacing: number('paragraphSpacing', 8, 0, 24),
      messageSpacing: number('messageSpacing', 24, 8, 48),
      messagePadding: number('messagePadding', 32, 12, 72),
      adaptiveMessagePadding: flag('adaptiveMessagePadding') ?? true,
      popoverMaxHeight: number('popoverMaxHeight', 420, 280, 600),
      popoverTopMargin: number('popoverTopMargin', 40, 16, 64),
      colorTheme: _migrateColorTheme(
        ColorThemePref.fromWire(str('colorTheme')),
        json['styleVersion'],
      ),
      cornerStyle: CornerStylePref.fromWire(str('cornerStyle')),
      chatSurface: ChatSurfacePref.fromWire(str('chatSurface')),
      liveMarkdown: flag('liveMarkdown') ?? true,
      ttsSpeed: TtsSpeedPref.fromWire(str('ttsSpeed')),
      ttsAutoEmotion: flag('ttsAutoEmotion') ?? true,
      ttsVoicePackId: str('ttsVoicePackId') ?? '',
    );
  }
}
