import 'dart:typed_data';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'terminal_connection.dart';
import 'local_shell_io.dart';

Future<TerminalConnection> openLocalTerminal(
  String root,
  int columns,
  int rows,
) async {
  // ConPTY handles console editing, completion, signals and VT output.
  final shell = resolveLocalShell();
  final directory = root.startsWith(r'\\?\UNC\')
      ? r'\\' + root.substring(8)
      : root.startsWith(r'\\?\')
      ? root.substring(4)
      : root;
  return _LocalTerminal(
    await Pty.spawn(
      PtySpawnOptions(
        executable: shell.executable,
        // Interactive shell, including its normal profile and completion/history.
        arguments: shell.arguments,
        workingDirectory: directory,
        environment: const PtyEnvironment.inherit(
          overrides: {'TERM': 'xterm-256color'},
        ),
        size: PtySize(columns: columns, rows: rows),
      ),
    ),
    shell.label,
  );
}

class _LocalTerminal implements TerminalConnection, TerminalShellInfo {
  _LocalTerminal(this.pty, this.shellLabel);
  final PtySession pty;
  @override
  final String shellLabel;
  bool _closed = false, _exited = false;
  late final Future<int?> _exitCode = pty.done
      .then(
        (exit) => switch (exit) {
          PtyExitCode(:final code) => code,
          PtySignalExit(:final signal) => -signal,
        },
      )
      .whenComplete(() => _exited = true);
  @override
  Stream<List<int>> get output => pty.output;
  @override
  Future<int?> get exitCode => _exitCode;
  @override
  Future<void> write(List<int> bytes) async {
    if (!_closed && !_exited) await pty.input.write(Uint8List.fromList(bytes));
  }

  @override
  void resize(int columns, int rows) {
    if (!_closed && !_exited && columns > 0 && rows > 0) {
      pty.resize(PtySize(columns: columns, rows: rows));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await pty.close();
  }
}
