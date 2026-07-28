/// Filters dangerous terminal input before it reaches the remote PTY.
///
/// ASCII ETX (0x03) is Ctrl+C — interrupts the foreground process. FS (0x1C) is
/// Ctrl+\ — SIGQUIT, which kills it just as dead. When observing a long training
/// job inside tmux, either one arriving by accident is catastrophic.
abstract final class TerminalInputGuard {
  /// ASCII End-of-Text = Ctrl+C (SIGINT).
  static const int ctrlCCodeUnit = 0x03;

  /// ASCII File-Separator = Ctrl+\ (SIGQUIT).
  static const int ctrlBackslashCodeUnit = 0x1c;

  static final String ctrlC = String.fromCharCode(ctrlCCodeUnit);
  static final String ctrlBackslash = String.fromCharCode(
    ctrlBackslashCodeUnit,
  );

  /// Control characters that terminate the foreground job.
  static final List<String> interruptChars = [ctrlC, ctrlBackslash];

  /// Returns the string to write and whether any interrupt char was stripped.
  static ({String data, bool blockedInterrupt}) filter(
    String input, {
    required bool blockInterrupt,
  }) {
    if (!blockInterrupt || input.isEmpty) {
      return (data: input, blockedInterrupt: false);
    }
    var data = input;
    var blocked = false;
    for (final ch in interruptChars) {
      if (!data.contains(ch)) continue;
      data = data.replaceAll(ch, '');
      blocked = true;
    }
    return (data: data, blockedInterrupt: blocked);
  }

  /// Maps a printable letter to its control code while a Ctrl latch is held.
  ///
  /// Returns null when [input] is not a single latchable character, so the
  /// caller can pass it through untouched. Mirrors what a hardware Ctrl key
  /// does: `a`/`A` → 0x01 … `z`/`Z` → 0x1A, plus the `@[\]^_` block.
  static String? applyCtrlLatch(String input) {
    if (input.length != 1) return null;
    final c = input.codeUnitAt(0);
    // a-z / A-Z → 0x01-0x1A
    if (c >= 0x61 && c <= 0x7a) return String.fromCharCode(c - 0x60);
    if (c >= 0x41 && c <= 0x5a) return String.fromCharCode(c - 0x40);
    // @ [ \ ] ^ _ → 0x00-0x1F block, and ? → DEL (0x7F), as on a real terminal.
    if (c >= 0x40 && c <= 0x5f) return String.fromCharCode(c - 0x40);
    if (c == 0x3f) return String.fromCharCode(0x7f);
    return null;
  }
}
