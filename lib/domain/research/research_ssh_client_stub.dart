import 'dart:async';

import '../../data/research/ssh_profile.dart';
import 'research_ssh_contract.dart';

export 'research_ssh_contract.dart';

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
  String? get interactiveTty => null;

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
  bool write(List<int> data) => false;

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
