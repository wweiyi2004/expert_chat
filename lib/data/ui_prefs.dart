/// User-facing appearance / reading preferences (persisted in settings).
enum TextScalePref {
  small,
  medium,
  large;

  String get label => switch (this) {
    TextScalePref.small => '小',
    TextScalePref.medium => '中',
    TextScalePref.large => '大',
  };

  double get scale => switch (this) {
    TextScalePref.small => 0.9,
    TextScalePref.medium => 1.0,
    TextScalePref.large => 1.12,
  };

  String get wire => name;

  static TextScalePref fromWire(String? v) => TextScalePref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => TextScalePref.medium,
  );
}

enum DensityPref {
  comfortable,
  compact;

  String get label => switch (this) {
    DensityPref.comfortable => '舒适',
    DensityPref.compact => '紧凑',
  };

  String get wire => name;

  static DensityPref fromWire(String? v) => DensityPref.values.firstWhere(
    (e) => e.name == v,
    orElse: () => DensityPref.comfortable,
  );
}

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

enum ContentWidthPref {
  narrow,
  regular,
  wide;

  String get label => switch (this) {
    ContentWidthPref.narrow => '窄',
    ContentWidthPref.regular => '标准',
    ContentWidthPref.wide => '宽',
  };

  /// Max width of the message column (phone ignores — full width).
  double get maxWidth => switch (this) {
    ContentWidthPref.narrow => 640,
    ContentWidthPref.regular => 800,
    ContentWidthPref.wide => 1100,
  };

  String get wire => name;

  static ContentWidthPref fromWire(String? v) => ContentWidthPref.values
      .firstWhere((e) => e.name == v, orElse: () => ContentWidthPref.regular);
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
    this.contentWidth = ContentWidthPref.regular,
    this.liveMarkdown = true,
    this.ttsSpeed = TtsSpeedPref.normal,
  });

  final TextScalePref textScale;
  final DensityPref density;
  final MessageStylePref messageStyle;
  final ContentWidthPref contentWidth;

  /// When true, stream assistant replies as live Markdown (not plain text).
  final bool liveMarkdown;

  /// Read-aloud speed, independent from visual text size.
  final TtsSpeedPref ttsSpeed;

  UiPrefs copyWith({
    TextScalePref? textScale,
    DensityPref? density,
    MessageStylePref? messageStyle,
    ContentWidthPref? contentWidth,
    bool? liveMarkdown,
    TtsSpeedPref? ttsSpeed,
  }) => UiPrefs(
    textScale: textScale ?? this.textScale,
    density: density ?? this.density,
    messageStyle: messageStyle ?? this.messageStyle,
    contentWidth: contentWidth ?? this.contentWidth,
    liveMarkdown: liveMarkdown ?? this.liveMarkdown,
    ttsSpeed: ttsSpeed ?? this.ttsSpeed,
  );

  Map<String, dynamic> toJson() => {
    'textScale': textScale.wire,
    'density': density.wire,
    'messageStyle': messageStyle.wire,
    'contentWidth': contentWidth.wire,
    'liveMarkdown': liveMarkdown,
    'ttsSpeed': ttsSpeed.wire,
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
      contentWidth: ContentWidthPref.fromWire(str('contentWidth')),
      liveMarkdown: flag('liveMarkdown') ?? true,
      ttsSpeed: TtsSpeedPref.fromWire(str('ttsSpeed')),
    );
  }
}
