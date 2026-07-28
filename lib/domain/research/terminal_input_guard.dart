/// Filters dangerous terminal input before it reaches the remote PTY.
///
/// ASCII ETX (0x03) is Ctrl+C — interrupts the foreground process. When
/// observing a long training job inside tmux, accidental Ctrl+C is catastrophic.
abstract final class TerminalInputGuard {
  /// ASCII End-of-Text = Ctrl+C.
  static const int ctrlCCodeUnit = 0x03;
  static final String ctrlC = String.fromCharCode(ctrlCCodeUnit);

  /// Returns the string to write and whether any Ctrl+C was stripped.
  static ({String data, bool blockedCtrlC}) filter(
    String input, {
    required bool blockCtrlC,
  }) {
    if (!blockCtrlC || input.isEmpty) {
      return (data: input, blockedCtrlC: false);
    }
    if (!input.contains(ctrlC)) {
      return (data: input, blockedCtrlC: false);
    }
    return (
      data: input.replaceAll(ctrlC, ''),
      blockedCtrlC: true,
    );
  }
}
