import 'dart:async';
import 'dart:convert';

import '../../data/research/ssh_profile.dart';
import 'research_ssh_client.dart';
import 'shell_quoting.dart';

/// Orchestrates remote tmux via non-interactive SSH exec / shell write.
class TmuxService {
  const TmuxService();

  static const listCommand =
      "tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_windows}'";

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

  /// Default tmux prefix is Ctrl-B (0x02).
  static const int defaultPrefixCodeUnit = 0x02; // Ctrl-B

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
    client.write(utf8.encode(attachSessionCommand(safe)));
  }

  /// Server-side detach of every client attached to [name].
  ///
  /// Prefer this over writing `prefix d` into the PTY: the key sequence is only
  /// meaningful when the shell really is inside tmux, and when it is not, the
  /// bytes land in the user's command line (Ctrl-B moves the cursor, `d`
  /// inserts a character). Going through exec is inert if the session is gone.
  String detachClientCommand(String name) =>
      'tmux detach-client -s ${shellSingleQuote(name)}';

  /// Detach the interactive client. Does **not** kill the session or jobs.
  Future<void> detachSession(ResearchSshClient client, String name) async {
    final safe = name.trim();
    if (safe.isEmpty) return;
    await client.runExec(detachClientCommand(safe));
  }

  /// Gap between the prefix key and the command that follows it.
  ///
  /// tmux must process `C-b` before the next byte arrives, otherwise the `:`
  /// reaches the pane as literal input. This is timing-dependent by nature —
  /// there is no ack to wait on — so the window is sized for a slow link
  /// rather than a fast one.
  static const prefixSettleDelay = Duration(milliseconds: 150);

  /// Switch to another session while already attached (no full detach UX).
  ///
  /// Uses tmux command mode: `C-b :switch-client -t <name>`. Session names are
  /// restricted to the same safe charset as create.
  Future<void> switchClientInShell(
    ResearchSshClient client,
    String name,
  ) async {
    final safe = name.trim();
    if (safe.isEmpty || !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(safe)) {
      throw ArgumentError('非法的 tmux 会话名');
    }
    client.write([defaultPrefixCodeUnit]);
    await Future<void>.delayed(prefixSettleDelay);
    // Enter command prompt, switch client, confirm.
    client.write(utf8.encode(':switch-client -t $safe\n'));
  }

  /// Attach if outside tmux; switch-client if already inside a session.
  Future<void> switchOrAttachInShell(
    ResearchSshClient client,
    String name, {
    required bool currentlyInTmux,
  }) async {
    final safe = name.trim();
    if (safe.isEmpty) return;
    if (currentlyInTmux) {
      await switchClientInShell(client, safe);
    } else {
      attachInShell(client, safe);
    }
  }
}

class TmuxNotInstalledException implements Exception {
  @override
  String toString() => '远端未安装 tmux';
}
