import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

TerminalTheme workspaceTerminalTheme(ColorScheme colors) {
  const base = TerminalThemes.defaultTheme;
  final light = colors.brightness == Brightness.light;
  // PSReadLine emits explicit ANSI colors (37 default text, 93 commands,
  // 92 variables), so changing foreground/background alone is insufficient.
  // Keep their semantic hues, but use dark inks on a light terminal surface.
  return TerminalTheme(
    cursor: colors.onSurface,
    selection: colors.primary.withValues(alpha: .25),
    foreground: colors.onSurface,
    background: colors.surface,
    black: light ? const Color(0xFF24232A) : base.black,
    red: light ? const Color(0xFFB3261E) : base.red,
    green: light ? const Color(0xFF267040) : base.green,
    yellow: light ? const Color(0xFF795900) : base.yellow,
    blue: light ? const Color(0xFF245CB2) : base.blue,
    magenta: light ? const Color(0xFF824498) : base.magenta,
    cyan: light ? const Color(0xFF006C78) : base.cyan,
    white: light ? colors.onSurface : base.white,
    brightBlack: light ? const Color(0xFF62616B) : base.brightBlack,
    brightRed: light ? const Color(0xFFB52C27) : base.brightRed,
    brightGreen: light ? const Color(0xFF237442) : base.brightGreen,
    brightYellow: light ? const Color(0xFF806000) : base.brightYellow,
    brightBlue: light ? const Color(0xFF2456A8) : base.brightBlue,
    brightMagenta: light ? const Color(0xFF8B3C96) : base.brightMagenta,
    brightCyan: light ? const Color(0xFF006979) : base.brightCyan,
    brightWhite: light ? colors.onSurface : base.brightWhite,
    searchHitBackground: colors.primaryContainer,
    searchHitBackgroundCurrent: colors.secondaryContainer,
    searchHitForeground: colors.onPrimaryContainer,
  );
}
