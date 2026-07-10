import 'package:flutter/material.dart';

/// Calm Material 3 themes with a restrained ink-blue accent.
///
/// The palette deliberately avoids neon gradients and overly saturated "AI"
/// blues: the conversation should feel like a focused work surface rather than
/// a dashboard competing with the answer.
class AppTheme {
  static const _seed = Color(0xFF365C8D);
  static const _lightSurface = Color(0xFFF7F8FA);
  static const _lightSurfacePanel = Color(0xFFFFFFFF);
  static const _lightInput = Color(0xFFF1F4F7);
  static const _lightBorder = Color(0xFFDCE3EA);
  static const _darkSurface = Color(0xFF111827);
  static const _darkSurfacePanel = Color(0xFF172132);
  static const _darkInput = Color(0xFF202C3D);
  static const _darkBorder = Color(0xFF314158);

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
          ? const Color(0xFF25436A)
          : const Color(0xFFE8EFF8),
      onPrimaryContainer: isDark
          ? const Color(0xFFEAF1FB)
          : const Color(0xFF23446D),
      secondary: const Color(0xFF177D71),
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
        helperStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: inputFill,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: border),
        labelStyle: TextStyle(color: scheme.onSurface),
        secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.all(12),
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedColor: scheme.primary,
        selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.65),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
        ),
      ),
    );
  }
}
