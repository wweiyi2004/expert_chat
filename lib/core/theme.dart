import 'package:flutter/material.dart';

import '../data/ui_prefs.dart';

/// Shared radii / bubble metrics so widgets can follow [CornerStylePref].
@immutable
class AppMetrics extends ThemeExtension<AppMetrics> {
  static const double space4 = 4,
      space8 = 8,
      space12 = 12,
      space16 = 16,
      space24 = 24,
      space32 = 32;
  static const double radiusSmall = 8, radiusMedium = 12, radiusLarge = 18;
  static const double minTapTarget = 44;
  static const motionFast = Duration(milliseconds: 150);
  static const motionBase = Duration(milliseconds: 200);
  static const motionReorder = Duration(milliseconds: 280);
  static const motionCurve = Cubic(0.2, 0, 0, 1);
  const AppMetrics({
    required this.radiusMd,
    required this.radiusLg,
    required this.bubbleMain,
    required this.bubbleTail,
    required this.chatSurface,
    this.lineHeight = 1.7,
    this.paragraphSpacing = 8,
    this.messageSpacing = 14,
    this.popoverMaxHeight = 420,
    this.popoverTopMargin = 40,
  });

  final double radiusMd;
  final double radiusLg;
  final double bubbleMain;
  final double bubbleTail;
  final ChatSurfacePref chatSurface;
  final double lineHeight,
      paragraphSpacing,
      messageSpacing,
      popoverMaxHeight,
      popoverTopMargin;

  factory AppMetrics.fromPrefs(UiPrefs ui) => AppMetrics(
    radiusMd: ui.cornerStyle.radiusMd,
    radiusLg: ui.cornerStyle.radiusLg,
    bubbleMain: ui.cornerStyle.bubbleMain,
    bubbleTail: ui.cornerStyle.bubbleTail,
    chatSurface: ui.chatSurface,
    lineHeight: ui.lineHeight,
    paragraphSpacing: ui.paragraphSpacing,
    messageSpacing: ui.messageSpacing,
    popoverMaxHeight: ui.popoverMaxHeight,
    popoverTopMargin: ui.popoverTopMargin,
  );

  BorderRadius get bubbleUser => BorderRadius.only(
    topLeft: Radius.circular(bubbleMain),
    topRight: Radius.circular(bubbleMain),
    bottomLeft: Radius.circular(bubbleMain),
    bottomRight: Radius.circular(bubbleTail),
  );

  BorderRadius get bubbleAssistant => BorderRadius.only(
    topLeft: Radius.circular(bubbleTail),
    topRight: Radius.circular(bubbleMain),
    bottomLeft: Radius.circular(bubbleMain),
    bottomRight: Radius.circular(bubbleMain),
  );

  @override
  AppMetrics copyWith({
    double? radiusMd,
    double? radiusLg,
    double? bubbleMain,
    double? bubbleTail,
    ChatSurfacePref? chatSurface,
    double? lineHeight,
    double? paragraphSpacing,
    double? messageSpacing,
    double? popoverMaxHeight,
    double? popoverTopMargin,
  }) => AppMetrics(
    radiusMd: radiusMd ?? this.radiusMd,
    radiusLg: radiusLg ?? this.radiusLg,
    bubbleMain: bubbleMain ?? this.bubbleMain,
    bubbleTail: bubbleTail ?? this.bubbleTail,
    chatSurface: chatSurface ?? this.chatSurface,
    lineHeight: lineHeight ?? this.lineHeight,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    messageSpacing: messageSpacing ?? this.messageSpacing,
    popoverMaxHeight: popoverMaxHeight ?? this.popoverMaxHeight,
    popoverTopMargin: popoverTopMargin ?? this.popoverTopMargin,
  );

  @override
  AppMetrics lerp(ThemeExtension<AppMetrics>? other, double t) {
    if (other is! AppMetrics) return this;
    return AppMetrics(
      radiusMd: lerpDouble(radiusMd, other.radiusMd, t) ?? radiusMd,
      radiusLg: lerpDouble(radiusLg, other.radiusLg, t) ?? radiusLg,
      bubbleMain: lerpDouble(bubbleMain, other.bubbleMain, t) ?? bubbleMain,
      bubbleTail: lerpDouble(bubbleTail, other.bubbleTail, t) ?? bubbleTail,
      chatSurface: t < 0.5 ? chatSurface : other.chatSurface,
      lineHeight: lerpDouble(lineHeight, other.lineHeight, t)!,
      paragraphSpacing: lerpDouble(
        paragraphSpacing,
        other.paragraphSpacing,
        t,
      )!,
      messageSpacing: lerpDouble(messageSpacing, other.messageSpacing, t)!,
      popoverMaxHeight: lerpDouble(
        popoverMaxHeight,
        other.popoverMaxHeight,
        t,
      )!,
      popoverTopMargin: lerpDouble(
        popoverTopMargin,
        other.popoverTopMargin,
        t,
      )!,
    );
  }
}

double? lerpDouble(double a, double b, double t) => a + (b - a) * t;

/// Execution meaning remains stable when the user changes the accent palette.
class AppStatusColors {
  const AppStatusColors._(this.dark);
  final bool dark;
  static AppStatusColors of(BuildContext context) =>
      AppStatusColors._(Theme.of(context).brightness == Brightness.dark);
  Color get running => Color(dark ? 0xFFF0AA40 : 0xFF9A5B00);
  Color get confirmation => Color(dark ? 0xFFF27A64 : 0xFFB53627);
  Color get completed => Color(dark ? 0xFF3FC6AF : 0xFF087969);
  Color get faint => Color(dark ? 0xFF9299A5 : 0xFF717985);
  Color get runningSoft => Color(dark ? 0xFF3A2A10 : 0xFFFFF1D9);
  Color get confirmationSoft => Color(dark ? 0xFF3B1C17 : 0xFFFDE8E4);
  Color get completedSoft => Color(dark ? 0xFF11322D : 0xFFDCF3EE);
}

/// Palette knobs for [AppTheme].
class _Palette {
  const _Palette({
    required this.seed,
    required this.accent,
    required this.lightSurface,
    required this.lightPanel,
    required this.lightInput,
    required this.lightBorder,
    required this.lightInk,
    required this.darkSurface,
    required this.darkPanel,
    required this.darkInput,
    required this.darkBorder,
    required this.darkInk,
  });

  final Color seed;
  final Color accent;
  final Color lightSurface;
  final Color lightPanel;
  final Color lightInput;
  final Color lightBorder;
  final Color lightInk;
  final Color darkSurface;
  final Color darkPanel;
  final Color darkInput;
  final Color darkBorder;
  final Color darkInk;

  static _Palette of(ColorThemePref theme) => switch (theme) {
    // Default since 2026-09: white page, light gray panels, one blue accent.
    ColorThemePref.minimal => const _Palette(
      seed: Color(0xFF4D6BFE),
      accent: Color(0xFF111827),
      lightSurface: Color(0xFFFFFFFF),
      lightPanel: Color(0xFFF7F7F8),
      lightInput: Color(0xFFF3F4F6),
      lightBorder: Color(0xFFE5E7EB),
      lightInk: Color(0xFF111827),
      darkSurface: Color(0xFF0F0F10),
      darkPanel: Color(0xFF1C1C1E),
      darkInput: Color(0xFF26262A),
      darkBorder: Color(0xFF2C2C2E),
      darkInk: Color(0xFFECECEC),
    ),
    ColorThemePref.inkTeal => const _Palette(
      seed: Color(0xFF1F5C6B),
      accent: Color(0xFFC45C26),
      lightSurface: Color(0xFFF4F1EA),
      lightPanel: Color(0xFFFFFCF7),
      lightInput: Color(0xFFEFEAE1),
      lightBorder: Color(0xFFDDD4C6),
      lightInk: Color(0xFF1C2430),
      darkSurface: Color(0xFF121820),
      darkPanel: Color(0xFF1A222D),
      darkInput: Color(0xFF232C38),
      darkBorder: Color(0xFF334155),
      darkInk: Color(0xFFE8EEF5),
    ),
    ColorThemePref.ocean => const _Palette(
      seed: Color(0xFF2B6CB0),
      accent: Color(0xFF0D9488),
      lightSurface: Color(0xFFF0F5FA),
      lightPanel: Color(0xFFF8FBFE),
      lightInput: Color(0xFFE4EEF7),
      lightBorder: Color(0xFFC9D9E8),
      lightInk: Color(0xFF1A2B3C),
      darkSurface: Color(0xFF0F1724),
      darkPanel: Color(0xFF172033),
      darkInput: Color(0xFF1E2A40),
      darkBorder: Color(0xFF334155),
      darkInk: Color(0xFFE2EAF4),
    ),
    ColorThemePref.forest => const _Palette(
      seed: Color(0xFF2F6B4F),
      accent: Color(0xFFB45309),
      lightSurface: Color(0xFFF1F5F0),
      lightPanel: Color(0xFFF8FBF7),
      lightInput: Color(0xFFE4EDE5),
      lightBorder: Color(0xFFC9D6CB),
      lightInk: Color(0xFF1A2A20),
      darkSurface: Color(0xFF101814),
      darkPanel: Color(0xFF18241C),
      darkInput: Color(0xFF223028),
      darkBorder: Color(0xFF3A4A40),
      darkInk: Color(0xFFE4EEE7),
    ),
    ColorThemePref.rose => const _Palette(
      seed: Color(0xFFB04A6E),
      accent: Color(0xFF7C3AED),
      lightSurface: Color(0xFFFAF5F7),
      lightPanel: Color(0xFFFFFBFC),
      lightInput: Color(0xFFF3E6EB),
      lightBorder: Color(0xFFE4CCD6),
      lightInk: Color(0xFF2A1820),
      darkSurface: Color(0xFF181218),
      darkPanel: Color(0xFF241820),
      darkInput: Color(0xFF302028),
      darkBorder: Color(0xFF4A3540),
      darkInk: Color(0xFFF2E6EC),
    ),
    ColorThemePref.violet => const _Palette(
      seed: Color(0xFF6B5B95),
      accent: Color(0xFFDB2777),
      lightSurface: Color(0xFFF5F3F9),
      lightPanel: Color(0xFFFCFAFE),
      lightInput: Color(0xFFEBE6F3),
      lightBorder: Color(0xFFD4CCE3),
      lightInk: Color(0xFF1E1830),
      darkSurface: Color(0xFF14121C),
      darkPanel: Color(0xFF1C1828),
      darkInput: Color(0xFF282438),
      darkBorder: Color(0xFF403850),
      darkInk: Color(0xFFECE6F5),
    ),
    ColorThemePref.amber => const _Palette(
      seed: Color(0xFFB7791F),
      accent: Color(0xFF0F766E),
      lightSurface: Color(0xFFFAF6EF),
      lightPanel: Color(0xFFFFFCF7),
      lightInput: Color(0xFFF1E8D8),
      lightBorder: Color(0xFFE0D2B8),
      lightInk: Color(0xFF2A2114),
      darkSurface: Color(0xFF16120C),
      darkPanel: Color(0xFF221C14),
      darkInput: Color(0xFF2E261C),
      darkBorder: Color(0xFF4A4030),
      darkInk: Color(0xFFF2EADF),
    ),
    ColorThemePref.slate => const _Palette(
      seed: Color(0xFF4A5568),
      accent: Color(0xFF64748B),
      lightSurface: Color(0xFFF4F5F7),
      lightPanel: Color(0xFFFBFBFC),
      lightInput: Color(0xFFE8EAEE),
      lightBorder: Color(0xFFD0D5DD),
      lightInk: Color(0xFF1A1F2A),
      darkSurface: Color(0xFF111418),
      darkPanel: Color(0xFF1A1E24),
      darkInput: Color(0xFF252A32),
      darkBorder: Color(0xFF3A4250),
      darkInk: Color(0xFFE6EAF0),
    ),
    // Nord — polar night / frost (arctic UI classic).
    ColorThemePref.nord => const _Palette(
      seed: Color(0xFF5E81AC),
      accent: Color(0xFF88C0D0),
      lightSurface: Color(0xFFECEFF4),
      lightPanel: Color(0xFFE5E9F0),
      lightInput: Color(0xFFD8DEE9),
      lightBorder: Color(0xFFC7D0DC),
      lightInk: Color(0xFF2E3440),
      darkSurface: Color(0xFF2E3440),
      darkPanel: Color(0xFF3B4252),
      darkInput: Color(0xFF434C5E),
      darkBorder: Color(0xFF4C566A),
      darkInk: Color(0xFFECEFF4),
    ),
    // GitHub Primer-inspired professional blue + success green accent.
    ColorThemePref.primer => const _Palette(
      seed: Color(0xFF0969DA),
      accent: Color(0xFF1A7F37),
      lightSurface: Color(0xFFF6F8FA),
      lightPanel: Color(0xFFFFFFFF),
      lightInput: Color(0xFFEFF2F5),
      lightBorder: Color(0xFFD0D7DE),
      lightInk: Color(0xFF1F2328),
      darkSurface: Color(0xFF0D1117),
      darkPanel: Color(0xFF161B22),
      darkInput: Color(0xFF21262D),
      darkBorder: Color(0xFF30363D),
      darkInk: Color(0xFFE6EDF3),
    ),
    // Stripe-inspired indigo brand energy.
    ColorThemePref.stripe => const _Palette(
      seed: Color(0xFF635BFF),
      accent: Color(0xFF0A2540),
      lightSurface: Color(0xFFF6F9FC),
      lightPanel: Color(0xFFFFFFFF),
      lightInput: Color(0xFFEEF2F7),
      lightBorder: Color(0xFFD6E0EB),
      lightInk: Color(0xFF0A2540),
      darkSurface: Color(0xFF0A2540),
      darkPanel: Color(0xFF112B4A),
      darkInput: Color(0xFF1A3658),
      darkBorder: Color(0xFF2D4A6F),
      darkInk: Color(0xFFF6F9FC),
    ),
    // Apple HIG-like system blue on graphite neutrals.
    ColorThemePref.graphite => const _Palette(
      seed: Color(0xFF007AFF),
      accent: Color(0xFF5856D6),
      lightSurface: Color(0xFFF2F2F7),
      lightPanel: Color(0xFFFFFFFF),
      lightInput: Color(0xFFE5E5EA),
      lightBorder: Color(0xFFD1D1D6),
      lightInk: Color(0xFF1C1C1E),
      darkSurface: Color(0xFF000000),
      darkPanel: Color(0xFF1C1C1E),
      darkInput: Color(0xFF2C2C2E),
      darkBorder: Color(0xFF3A3A3C),
      darkInk: Color(0xFFF2F2F7),
    ),
    // Warm terracotta / editorial clay.
    ColorThemePref.clay => const _Palette(
      seed: Color(0xFFC15F3C),
      accent: Color(0xFF5C4033),
      lightSurface: Color(0xFFFAF6F2),
      lightPanel: Color(0xFFFFFBF7),
      lightInput: Color(0xFFF0E6DC),
      lightBorder: Color(0xFFDFD0C2),
      lightInk: Color(0xFF2C211C),
      darkSurface: Color(0xFF1A1412),
      darkPanel: Color(0xFF261C18),
      darkInput: Color(0xFF322620),
      darkBorder: Color(0xFF4A3A32),
      darkInk: Color(0xFFF5EDE6),
    ),
    // Solarized-inspired (Ethan Schoonover) — blue seed, yellow accent.
    ColorThemePref.solar => const _Palette(
      seed: Color(0xFF268BD2),
      accent: Color(0xFFB58900),
      lightSurface: Color(0xFFFDF6E3),
      lightPanel: Color(0xFFEEE8D5),
      lightInput: Color(0xFFE6DFC8),
      lightBorder: Color(0xFFD3CBB3),
      lightInk: Color(0xFF657B83),
      darkSurface: Color(0xFF002B36),
      darkPanel: Color(0xFF073642),
      darkInput: Color(0xFF0A3F4C),
      darkBorder: Color(0xFF586E75),
      darkInk: Color(0xFF93A1A1),
    ),
    ColorThemePref.dailan => const _Palette(
      seed: Color(0xFF1179AD),
      accent: Color(0xFF617581),
      lightSurface: Color(0xFFF7FBFC),
      lightPanel: Color(0xFFEEF5F6),
      lightInput: Color(0xFFE7EEF0),
      lightBorder: Color(0xFFD6DEE0),
      lightInk: Color(0xFF1A2435),
      darkSurface: Color(0xFF111419),
      darkPanel: Color(0xFF161A20),
      darkInput: Color(0xFF1D2229),
      darkBorder: Color(0xFF2B313A),
      darkInk: Color(0xFFDFEAEC),
    ),
    ColorThemePref.yanzhi => const _Palette(
      seed: Color(0xFF9C2A33),
      accent: Color(0xFF876C75),
      lightSurface: Color(0xFFFBFAF8),
      lightPanel: Color(0xFFF4F3F0),
      lightInput: Color(0xFFEEEDE9),
      lightBorder: Color(0xFFDEDCD8),
      lightInk: Color(0xFF331E1A),
      darkSurface: Color(0xFF191211),
      darkPanel: Color(0xFF201716),
      darkInput: Color(0xFF291F1D),
      darkBorder: Color(0xFF392D2B),
      darkInk: Color(0xFFEBE8DF),
    ),
    ColorThemePref.zhuqing => const _Palette(
      seed: Color(0xFF627B4C),
      accent: Color(0xFF61776E),
      lightSurface: Color(0xFFFBFAF7),
      lightPanel: Color(0xFFF5F3EF),
      lightInput: Color(0xFFEFEDE8),
      lightBorder: Color(0xFFDEDCD7),
      lightInk: Color(0xFF1D2629),
      darkSurface: Color(0xFF0E1518),
      darkPanel: Color(0xFF121B1E),
      darkInput: Color(0xFF192327),
      darkBorder: Color(0xFF273237),
      darkInk: Color(0xFFEBE8DF),
    ),
    ColorThemePref.jiangzi => const _Palette(
      seed: Color(0xFF8C4356),
      accent: Color(0xFF88639D),
      lightSurface: Color(0xFFFEF8FA),
      lightPanel: Color(0xFFFAF1F4),
      lightInput: Color(0xFFF4EAED),
      lightBorder: Color(0xFFE5D9DD),
      lightInk: Color(0xFF252133),
      darkSurface: Color(0xFF141319),
      darkPanel: Color(0xFF1A181F),
      darkInput: Color(0xFF222029),
      darkBorder: Color(0xFF312F39),
      darkInk: Color(0xFFEFE5E8),
    ),
    ColorThemePref.wadaSienna => const _Palette(
      seed: Color(0xFFAE5224),
      accent: Color(0xFF9C6734),
      lightSurface: Color(0xFFF5FCF9),
      lightPanel: Color(0xFFEBF7F1),
      lightInput: Color(0xFFE3F1EA),
      lightBorder: Color(0xFFD1E1DA),
      lightInk: Color(0xFF17272D),
      darkSurface: Color(0xFF0E1518),
      darkPanel: Color(0xFF131B1E),
      darkInput: Color(0xFF192327),
      darkBorder: Color(0xFF273237),
      darkInk: Color(0xFFE1EBE6),
    ),
    ColorThemePref.wadaSulphur => const _Palette(
      seed: Color(0xFF064F6E),
      accent: Color(0xFFA2640C),
      lightSurface: Color(0xFFFCFAF3),
      lightPanel: Color(0xFFF6F4E8),
      lightInput: Color(0xFFF0EDE0),
      lightBorder: Color(0xFFE0DDCD),
      lightInk: Color(0xFF112732),
      darkSurface: Color(0xFF0F1518),
      darkPanel: Color(0xFF131B1F),
      darkInput: Color(0xFF1A2328),
      darkBorder: Color(0xFF283238),
      darkInk: Color(0xFFEAE8DF),
    ),
    ColorThemePref.wadaCossack => const _Palette(
      seed: Color(0xFF437742),
      accent: Color(0xFF60738D),
      lightSurface: Color(0xFFFCFAF3),
      lightPanel: Color(0xFFF6F4E8),
      lightInput: Color(0xFFF0EDE0),
      lightBorder: Color(0xFFE0DDCD),
      lightInk: Color(0xFF1A2819),
      darkSurface: Color(0xFF111510),
      darkPanel: Color(0xFF161B15),
      darkInput: Color(0xFF1D241D),
      darkBorder: Color(0xFF2B332B),
      darkInk: Color(0xFFEAE8DF),
    ),
    ColorThemePref.wadaViolet => const _Palette(
      seed: Color(0xFF6450A1),
      accent: Color(0xFF00807A),
      lightSurface: Color(0xFFF5FCFC),
      lightPanel: Color(0xFFEAF6F6),
      lightInput: Color(0xFFE3F0F0),
      lightBorder: Color(0xFFD1E0E0),
      lightInk: Color(0xFF331E19),
      darkSurface: Color(0xFF191210),
      darkPanel: Color(0xFF201715),
      darkInput: Color(0xFF291F1D),
      darkBorder: Color(0xFF392D2B),
      darkInk: Color(0xFFDFEAEB),
    ),
  };
}

/// Editorial desk themes driven by [UiPrefs] color / corner choices.
class AppTheme {
  static const _cjkFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Heiti SC',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'Noto Sans SC',
    'sans-serif',
  ];

  static ThemeData light([UiPrefs ui = const UiPrefs()]) =>
      _base(Brightness.light, ui);

  static ThemeData dark([UiPrefs ui = const UiPrefs()]) =>
      _base(Brightness.dark, ui);

  static ThemeData _base(Brightness brightness, UiPrefs ui) {
    final isDark = brightness == Brightness.dark;
    final palette = _Palette.of(ui.colorTheme);
    final r = ui.cornerStyle.radiusMd;
    final rLg = ui.cornerStyle.radiusLg;

    final generated = ColorScheme.fromSeed(
      seedColor: palette.seed,
      brightness: brightness,
    );
    final scheme = generated.copyWith(
      primary: isDark
          ? Color.lerp(palette.seed, Colors.white, 0.35)!
          : palette.seed,
      onPrimary: isDark
          ? Color.lerp(palette.seed, Colors.black, 0.75)!
          : Colors.white,
      secondary: isDark
          ? Color.lerp(palette.accent, Colors.white, 0.25)!
          : palette.accent,
      onSecondary: Colors.white,
      surface: isDark ? palette.darkSurface : palette.lightSurface,
      onSurface: isDark ? palette.darkInk : palette.lightInk,
      surfaceContainerLowest: isDark
          ? Color.lerp(palette.darkSurface, Colors.black, 0.25)!
          : Color.lerp(palette.lightSurface, palette.lightBorder, 0.35)!,
      surfaceContainerLow: isDark
          ? Color.lerp(palette.darkPanel, palette.darkSurface, 0.4)!
          : palette.lightInput,
      surfaceContainer: isDark ? palette.darkPanel : palette.lightPanel,
      surfaceContainerHigh: isDark
          ? Color.lerp(palette.darkPanel, palette.darkInput, 0.5)!
          : Color.lerp(palette.lightPanel, Colors.white, 0.4)!,
      surfaceContainerHighest: isDark ? palette.darkInput : palette.lightInput,
      outline: isDark ? palette.darkBorder : palette.lightBorder,
      outlineVariant: isDark
          ? Color.lerp(palette.darkBorder, palette.darkInk, 0.15)!
          : Color.lerp(palette.lightBorder, palette.lightSurface, 0.35)!,
      shadow: isDark ? Colors.black : palette.lightInk,
    );

    final border = scheme.outlineVariant;
    final inputFill = scheme.surfaceContainerHighest;
    final textTheme = _textTheme(scheme);
    final metrics = AppMetrics.fromPrefs(ui);

    return ThemeData(
      useMaterial3: true,
      iconTheme: IconThemeData(size: 20, color: scheme.onSurfaceVariant),
      colorScheme: scheme,
      fontFamily: 'NotoSansSC',
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      extensions: [metrics],
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        // Tone, not outlines, separates cards from the page.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        helperStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: inputFill,
        selectedColor: scheme.primaryContainer,
        side: BorderSide.none,
        labelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onSurface,
          fontSize: 13,
        ),
        secondaryLabelStyle: textTheme.labelLarge?.copyWith(
          color: scheme.onPrimaryContainer,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(r - 2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(32, 34),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: border),
          minimumSize: const Size(32, 34),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.all(9),
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(r - 2),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.onSurface,
        selectedTileColor: scheme.surfaceContainer,
        minVerticalPadding: 4,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        iconColor: scheme.onSurfaceVariant,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? Color.lerp(palette.darkPanel, Colors.black, 0.15)!
            : palette.lightInk,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(rLg + 4)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        elevation: 6,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(r + 2),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(r - 2)),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: border,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme) {
    TextStyle base(double size, FontWeight weight, {double? height}) =>
        TextStyle(
          fontFamily: 'NotoSansSC',
          fontFamilyFallback: _cjkFallback,
          fontSize: size,
          fontWeight: weight,
          height: height,
          color: scheme.onSurface,
        );

    return TextTheme(
      displaySmall: base(24, FontWeight.w600, height: 1.2),
      headlineSmall: base(20, FontWeight.w600, height: 1.25),
      titleLarge: base(18, FontWeight.w600, height: 1.3),
      titleMedium: base(15, FontWeight.w600, height: 1.35),
      titleSmall: base(14, FontWeight.w500, height: 1.35),
      bodyLarge: base(14, FontWeight.w400, height: 1.7),
      bodyMedium: base(14, FontWeight.w400, height: 1.6),
      bodySmall: base(12, FontWeight.w400, height: 1.4),
      labelLarge: base(13, FontWeight.w400, height: 1.2),
      labelMedium: base(12, FontWeight.w400, height: 1.2),
      labelSmall: base(11, FontWeight.w500, height: 1.2),
    );
  }

  /// Decorative chat / shell background based on [ChatSurfacePref].
  static BoxDecoration surfaceDecoration(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final metrics = Theme.of(context).extension<AppMetrics>();
    final surface = metrics?.chatSurface ?? ChatSurfacePref.plain;
    return switch (surface) {
      ChatSurfacePref.plain => BoxDecoration(color: scheme.surface),
      ChatSurfacePref.paper => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            scheme.surface,
            Color.lerp(scheme.surface, scheme.surfaceContainerLow, 0.55)!,
            scheme.surface,
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      ChatSurfacePref.tinted => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(scheme.surface, scheme.primary, 0.06)!,
            scheme.surface,
            Color.lerp(scheme.surface, scheme.secondary, 0.05)!,
          ],
        ),
      ),
    };
  }
}
