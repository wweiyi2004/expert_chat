import 'package:flutter/material.dart';

/// Ink-teal editorial desk: calm work surface, not neon AI chrome.
class AppTheme {
  static const _seed = Color(0xFF1F5C6B);
  static const _accent = Color(0xFFC45C26);

  static const _lightSurface = Color(0xFFF4F1EA);
  static const _lightPanel = Color(0xFFFFFCF7);
  static const _lightInput = Color(0xFFEFEAE1);
  static const _lightBorder = Color(0xFFDDD4C6);
  static const _lightInk = Color(0xFF1C2430);

  static const _darkSurface = Color(0xFF121820);
  static const _darkPanel = Color(0xFF1A222D);
  static const _darkInput = Color(0xFF232C38);
  static const _darkBorder = Color(0xFF334155);
  static const _darkInk = Color(0xFFE8EEF5);

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

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final generated = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final scheme = generated.copyWith(
      primary: isDark ? const Color(0xFF6BB8C6) : _seed,
      onPrimary: isDark ? const Color(0xFF00333C) : Colors.white,
      primaryContainer: isDark
          ? const Color(0xFF1A4550)
          : const Color(0xFFD5EBEF),
      onPrimaryContainer: isDark
          ? const Color(0xFFD7F2F7)
          : const Color(0xFF0B3A44),
      secondary: isDark ? const Color(0xFFE08A58) : _accent,
      onSecondary: Colors.white,
      secondaryContainer: isDark
          ? const Color(0xFF5A3118)
          : const Color(0xFFF7E0D2),
      onSecondaryContainer: isDark
          ? const Color(0xFFFFE8DA)
          : const Color(0xFF4A220C),
      tertiary: isDark ? const Color(0xFFB7A4E8) : const Color(0xFF5B4B8A),
      surface: isDark ? _darkSurface : _lightSurface,
      onSurface: isDark ? _darkInk : _lightInk,
      surfaceContainerLowest: isDark
          ? const Color(0xFF0D1218)
          : const Color(0xFFEDE8DF),
      surfaceContainerLow: isDark ? const Color(0xFF161D26) : _lightInput,
      surfaceContainer: isDark ? _darkPanel : _lightPanel,
      surfaceContainerHigh: isDark
          ? const Color(0xFF202936)
          : const Color(0xFFF8F4ED),
      surfaceContainerHighest: isDark ? _darkInput : _lightInput,
      outline: isDark ? _darkBorder : _lightBorder,
      outlineVariant: isDark
          ? const Color(0xFF3D4B5E)
          : const Color(0xFFE6DDD0),
      shadow: isDark ? Colors.black : const Color(0xFF1C2430),
    );

    final border = scheme.outlineVariant;
    final inputFill = scheme.surfaceContainerHighest;
    final textTheme = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'NotoSansSC',
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
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
          borderRadius: BorderRadius.circular(18),
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
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(48, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: border),
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
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
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.55),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        iconColor: scheme.onSurfaceVariant,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF243041) : _lightInk,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 6,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
}
