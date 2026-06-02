import 'package:flutter/material.dart';

/// Clean Material 3 themes with a calm seed color, tuned for a chat surface.
class AppTheme {
  static const _seed = Color(0xFF4D6BFE); // DeepSeek-ish blue

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
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Bundled Noto Sans SC for a uniform look on every platform; the system
      // fallbacks below only cover glyphs Noto might miss.
      fontFamily: 'NotoSansSC',
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
