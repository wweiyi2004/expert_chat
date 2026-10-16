import 'dart:async';
import 'dart:convert';

import '../../data/research/ssh_profile.dart';
import 'research_ssh_client.dart';
import 'shell_quoting.dart';

/// Controls attached tmux clients via SSH exec, scoped to the interactive TTY.
class TmuxService {
  const TmuxService();

  static const listCommand =
      "tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_windows}'";
  static const listClientsCommand =
      "tmux list-clients -F '#{client_tty}\t#{session_name}'";

  /// Parse `tmux list-sessions -F` output. Empty → no sessions.
  /// Throws [TmuxNotInstalledException] when stderr/output indicates missing tmux
  /// (caller may also detect via exit semantics of runExec failures).
  List<TmuxSessionInfo> parseListSessions(String output) {
    final lines = output
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];
    final sessions = <TmuxSessionInfo>[];
    for (final line in lines) {
      final parts = line.split('\t');
      if (parts.isEmpty) continue;
      final name = parts[0].trim();
      if (name.isEmpty) continue;
      final attached = parts.length > 1
          ? int.tryParse(parts[1].trim()) ?? 0
          : 0;
      final windows = parts.length > 2 ? int.tryParse(parts[2].trim()) ?? 1 : 1;
      sessions.add(
        TmuxSessionInfo(name: name, attached: attached, windows: windows),
      );
    }
    return sessions;
  }

  String newSessionCommand(String name) =>
      'tmux new-session -d -s ${shellSingleQuote(name)}';

  /// Written into the interactive shell so the user attaches in-place.
  String attachSessionCommand(String name) =>
      'tmux attach-session -t ${shellSingleQuote(name)}\n';

  Future<List<TmuxSessionInfo>> listSessions(ResearchSshClient client) async {
    try {
      // Do not sniff stdout for "not found": a session name may legitimately
      // contain that text. A missing binary shows up on stderr / exit 127,
      // which the ResearchSshExecException branch below handles.
      return parseListSessions(await client.runExec(listCommand));
    } on ResearchSshExecException catch (e) {
      final stderr = e.stderrText.toLowerCase();
      if (e.exitCode == 127 ||
          stderr.contains('command not found') ||
          stderr.contains('not found')) {
        throw TmuxNotInstalledException();
      }
      // tmux uses exit 1 when its server is not running / has no sessions.
      if (e.exitCode == 1 &&
          (stderr.contains('no server running') ||
              stderr.contains('no sessions') ||
              stderr.contains('failed to connect to server'))) {
        return const [];
      }
      rethrow;
    } on ResearchSshException {
      rethrow;
    }
  }

  Future<void> createSession(ResearchSshClient client, String name) async {
    final safe = name.trim();
    if (safe.isEmpty || !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(safe)) {
      throw ArgumentError('非法的 tmux 会话名');
    }
    await client.runExec(newSessionCommand(safe));
  }

  void attachInShell(ResearchSshClient client, String name) {
    final safe = name.trim();
    if (safe.isEmpty) return;
    if (!client.write(utf8.encode(attachSessionCommand(safe)))) {
      throw ResearchSshException('终端已断开，未发送 tmux 连接命令');
    }
  }

  String _tty(ResearchSshClient client) {
    final tty = client.interactiveTty;
    if (tty == null) throw ResearchSshException('当前终端 TTY 未就绪');
    return tty;
  }

  /// Identify this client's attachment, even if other terminals share it.
  Future<String?> currentSession(ResearchSshClient client) async {
    final tty = _tty(client);
    final String output;
    try {
      output = await client.runExec(listClientsCommand);
    } on ResearchSshExecException catch (e) {
      final stderr = e.stderrText.toLowerCase();
      if (e.exitCode == 1 &&
          (stderr.contains('no server running') ||
              stderr.contains('no sessions') ||
              stderr.contains('failed to connect to server'))) {
        return null;
      }
      rethrow;
    }
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final tab = line.indexOf('\t');
      if (tab >= 0 && line.substring(0, tab) == tty) {
        return line.substring(tab + 1);
      }
    }
    return null;
  }

  String detachClientCommand(String tty) =>
      'tmux detach-client -t ${shellSingleQuote(tty)}';

  /// Detach the interactive client. Does **not** kill the session or jobs.
  Future<void> detachSession(ResearchSshClient client) async {
    await client.runExec(detachClientCommand(_tty(client)));
  }

  /// Switch this TTY without sending command text into its foreground program.
  Future<void> switchClient(ResearchSshClient client, String name) async {
    final safe = name.trim();
    if (safe.isEmpty || !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(safe)) {
      throw ArgumentError('非法的 tmux 会话名');
    }
    await client.runExec(
      'tmux switch-client -c ${shellSingleQuote(_tty(client))} '
      '-t ${shellSingleQuote(safe)}',
    );
  }

  /// Attach if outside tmux; switch-client if already inside a session.
  Future<void> switchOrAttachInShell(
    ResearchSshClient client,
    String name,
  ) async {
    final safe = name.trim();
    if (safe.isEmpty) return;
    if (await currentSession(client) != null) {
      await switchClient(client, safe);
    } else {
      attachInShell(client, safe);
    }
  }
}

class TmuxNotInstalledException implements Exception {
  @override
  String toString() => '远端未安装 tmux';
}
