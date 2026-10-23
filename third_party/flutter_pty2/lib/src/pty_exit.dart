sealed class PtyExit {
  const PtyExit();
}

final class PtyExitCode extends PtyExit {
  const PtyExitCode(this.code);

  final int code;

  @override
  String toString() => 'PtyExitCode($code)';
}

final class PtySignalExit extends PtyExit {
  const PtySignalExit(this.signal);

  final int signal;

  @override
  String toString() => 'PtySignalExit($signal)';
}
