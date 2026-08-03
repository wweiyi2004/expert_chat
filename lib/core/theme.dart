import 'package:flutter/material.dart';

import '../data/ui_prefs.dart';

/// Shared radii / bubble metrics so widgets can follow [CornerStylePref].
@immutable
class AppMetrics extends ThemeExtension<AppMetrics> {
  const AppMetrics({
    required this.radiusMd,
    required this.radiusLg,
    required this.bubbleMain,
    required this.bubbleTail,
    required this.chatSurface,
  });

  final double radiusMd;
  final double radiusLg;
  final double bubbleMain;
  final double bubbleTail;
  final ChatSurfacePref chatSurface;

  factory AppMetrics.fromPrefs(UiPrefs ui) => AppMetrics(
    radiusMd: ui.cornerStyle.radiusMd,
    radiusLg: ui.cornerStyle.radiusLg,
    bubbleMain: ui.cornerStyle.bubbleMain,
    bubbleTail: ui.cornerStyle.bubbleTail,
    chatSurface: ui.chatSurface,
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
  }) => AppMetrics(
    radiusMd: radiusMd ?? this.radiusMd,
    radiusLg: radiusLg ?? this.radiusLg,
    bubbleMain: bubbleMain ?? this.bubbleMain,
    bubbleTail: bubbleTail ?? this.bubbleTail,
    chatSurface: chatSurface ?? this.chatSurface,
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
    );
  }
}

double? lerpDouble(double a, double b, double t) => a + (b - a) * t;

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
      colorScheme: scheme,
      fontFamily: 'NotoSansSC',
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      extensions: [metrics],
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface.withValues(alpha: 0.92),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLg),
          side: BorderSide(color: border.withValues(alpha: 0.9)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(r),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(r),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(r),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        helperStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: inputFill,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: border),
        labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r - 2)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(r),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: border),
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(r),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.all(10),
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(r - 2),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.55),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
        iconColor: scheme.onSurfaceVariant,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark
            ? Color.lerp(palette.darkPanel, Colors.black, 0.15)!
            : palette.lightInk,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(rLg + 4)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(r + 2)),
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
      displaySmall: base(28, FontWeight.w700, height: 1.2),
      headlineSmall: base(22, FontWeight.w700, height: 1.25),
      titleLarge: base(18, FontWeight.w700, height: 1.3),
      titleMedium: base(16, FontWeight.w600, height: 1.35),
      titleSmall: base(14, FontWeight.w600, height: 1.35),
      bodyLarge: base(15.5, FontWeight.w400, height: 1.65),
      bodyMedium: base(14, FontWeight.w400, height: 1.5),
      bodySmall: base(12.5, FontWeight.w400, height: 1.4),
      labelLarge: base(13.5, FontWeight.w600, height: 1.2),
      labelMedium: base(12, FontWeight.w600, height: 1.2),
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
