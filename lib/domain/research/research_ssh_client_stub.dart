import 'dart:async';

import '../../data/research/ssh_profile.dart';

/// Web / unsupported transport.
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

  void write(List<int> data);
  void resize({required int cols, required int rows});
  Future<String> runExec(String command, {Duration timeout});
  Future<void> disconnect();
}

ResearchSshClient createResearchSshClient() => _UnsupportedResearchSshClient();

class _UnsupportedResearchSshClient implements ResearchSshClient {
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<void> get done => Future.value();
  @override
  bool get isConnected => false;
  @override
  String? get lastHostKeyFingerprint => null;

  @override
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
  }) async {
    throw ResearchSshException('当前平台不支持原生 SSH 连接（例如浏览器）。');
  }

  @override
  void write(List<int> data) {}

  @override
  void resize({required int cols, required int rows}) {}

  @override
  Future<String> runExec(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    throw ResearchSshException('当前平台不支持原生 SSH 连接（例如浏览器）。');
  }

  @override
  Future<void> disconnect() async {}
}

/// Test double factory.
typedef ResearchSshClientFactory = ResearchSshClient Function();
