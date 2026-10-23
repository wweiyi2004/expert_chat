/// A user-owned interactive shell. Closing a tab closes only this shell.
abstract interface class TerminalConnection {
  Stream<List<int>> get output;
  Future<int?> get exitCode;
  Future<void> write(List<int> bytes);
  void resize(int columns, int rows);
  Future<void> close();
}

/// Optional presentation metadata; remote/custom terminals need not implement it.
abstract interface class TerminalShellInfo {
  String get shellLabel;
}
