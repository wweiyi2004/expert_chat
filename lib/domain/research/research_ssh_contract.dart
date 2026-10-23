import 'dart:async';
import 'package:dio/dio.dart';
import '../../data/research/ssh_profile.dart';
import '../desktop/command_runner_contract.dart';
import '../workbench/terminal/terminal_connection.dart';

export '../desktop/command_runner_contract.dart';

abstract interface class ResearchTerminalHost {
  Future<TerminalConnection> openTerminal(String root, int columns, int rows);
}

abstract interface class ResearchCommandHost {
  Future<String> runWorkspaceCommand(
    String command,
    Duration timeout,
    CancelToken token, {
    WorkspaceCommandOutput? onOutput,
    WorkspaceCommandCompletion? onComplete,
  });
}

class ResearchSshException implements Exception {
  ResearchSshException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ResearchSshExecException extends ResearchSshException {
  ResearchSshExecException({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
  }) : super('远程命令执行失败（退出码 ${exitCode ?? '未知'}）');

  final int? exitCode;
  final String stdoutText;
  final String stderrText;
}

class ResearchHostKeyInfo {
  const ResearchHostKeyInfo({
    required this.fingerprintSha256,
    required this.keyType,
  });
  final String fingerprintSha256;
  final String keyType;
}

/// Callback when a never-seen host key must be trusted by the user.
typedef HostKeyTrustHandler = Future<bool> Function(ResearchHostKeyInfo info);

/// Callback when a saved fingerprint no longer matches.
typedef HostKeyMismatchHandler =
    Future<bool> Function(ResearchHostKeyInfo info, String previousFingerprint);

abstract class ResearchSshClient {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<void> get done;
  bool get isConnected;
  String? get lastHostKeyFingerprint;

  /// Remote TTY of this interactive SSH channel, available after connect.
  String? get interactiveTty;

  /// Connect + auth + open interactive PTY shell.
  Future<void> connect({
    required SshProfile profile,
    required String? password,
    required String? privateKeyPem,
    required String? passphrase,
    required HostKeyTrustHandler onHostKeyTrust,
    required HostKeyMismatchHandler onHostKeyMismatch,
    int cols = 80,
    int rows = 24,
    Duration connectTimeout = const Duration(seconds: 15),
  });

  /// Returns false when the channel is gone and nothing was sent.
  bool write(List<int> data);
  void resize({required int cols, required int rows});
  Future<String> runExec(String command, {Duration timeout});
  Future<void> disconnect();
}

typedef ResearchSshClientFactory = ResearchSshClient Function();
