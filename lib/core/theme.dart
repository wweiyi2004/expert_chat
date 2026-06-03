import 'package:flutter/material.dart';

/// Clean Material 3 themes with a DeepSeek-like blue/white chat surface.
class AppTheme {
  static const _seed = Color(0xFF4D6BFE);
  static const _lightSurface = Color(0xFFF7FAFF);
  static const _lightSurfacePanel = Color(0xFFFFFFFF);
  static const _lightInput = Color(0xFFF3F7FF);
  static const _lightBorder = Color(0xFFDDE7FF);
  static const _darkSurface = Color(0xFF0D1424);
  static const _darkSurfacePanel = Color(0xFF111B2E);
  static const _darkInput = Color(0xFF17233A);
  static const _darkBorder = Color(0xFF243450);

  /// CJK font fallback chain. The default family (Segoe UI / Roboto / SF) has
  /// no Chinese glyphs, so without this Flutter falls back glyph-by-glyph to
  /// arbitrary system fonts — giving inconsistent shapes/weights and bad
  /// punctuation metrics. Pinning one good CJK font per platform makes all
  /// Chinese text come from a single, solid-weight face.
  static const _cjkFallback = <String>[
    'Microsoft YaHei UI', 'Microsoft YaHei', // Windows
    'PingFang SC', 'Heiti SC', // macOS / iOS
    'Noto Sans CJK SC', 'Source Han Sans SC', 'Noto Sans SC', // Android / Linux
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
      primary: _seed,
      onPrimary: Colors.white,
      primaryContainer: isDark
          ? const Color(0xFF223778)
          : const Color(0xFFE8EEFF),
      onPrimaryContainer: isDark
          ? const Color(0xFFE9EEFF)
          : const Color(0xFF263C8F),
      secondary: const Color(0xFF1AA6A6),
      surface: isDark ? _darkSurface : _lightSurface,
      surfaceContainer: isDark ? _darkSurfacePanel : _lightSurfacePanel,
      surfaceContainerHighest: isDark ? _darkInput : _lightInput,
      outline: isDark ? _darkBorder : _lightBorder,
      outlineVariant: isDark ? _darkBorder : _lightBorder,
    );
    final border = isDark ? _darkBorder : _lightBorder;
    final inputFill = isDark ? _darkInput : _lightInput;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Bundled Noto Sans SC for a uniform look on every platform; the system
      // fallbacks below only cover glyphs Noto might miss.
      fontFamily: 'NotoSansSC',
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: scheme.surface,
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          fontFamily: 'NotoSansSC',
          fontFamilyFallback: _cjkFallback,
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
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
        helperStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: inputFill,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: border),
        labelStyle: TextStyle(color: scheme.onSurface),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.65),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
        ),
      ),
    );
  }
}
