import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../data/research/ssh_profile.dart';

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

typedef HostKeyTrustHandler = Future<bool> Function(ResearchHostKeyInfo info);

typedef HostKeyMismatchHandler =
    Future<bool> Function(ResearchHostKeyInfo info, String previousFingerprint);

abstract class ResearchSshClient {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<void> get done;
  bool get isConnected;
  String? get lastHostKeyFingerprint;

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

ResearchSshClient createResearchSshClient() => ResearchSshClientIo();

typedef ResearchSshClientFactory = ResearchSshClient Function();

class ResearchSshClientIo implements ResearchSshClient {
  SSHClient? _client;
  SSHSession? _shell;
  final List<List<int>> _earlyStdout = [];
  final List<List<int>> _earlyStderr = [];
  var _earlyStdoutBytes = 0;
  var _earlyStderrBytes = 0;
  late StreamController<List<int>> _stdoutController = _newStdoutController();
  late StreamController<List<int>> _stderrController = _newStderrController();
  final List<StreamSubscription<dynamic>> _subs = [];
  var _connected = false;
  Completer<void>? _done;
  String? _lastFp;

  static const _maxEarlyStreamBytes = 256 * 1024;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;
  @override
  Stream<List<int>> get stderr => _stderrController.stream;
  @override
  Future<void> get done => _done?.future ?? Future.value();
  @override
  bool get isConnected => _connected;
  @override
  String? get lastHostKeyFingerprint => _lastFp;

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
    await _teardown(closeStreams: false);
    // disconnect() closes the output streams; a reconnect on the same instance
    // needs live ones again.
    if (_stdoutController.isClosed) _stdoutController = _newStdoutController();
    if (_stderrController.isClosed) _stderrController = _newStderrController();
    _done = Completer<void>();
    _lastFp = null;

    late final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        profile.host,
        profile.port,
        timeout: connectTimeout,
      );
    } catch (_) {
      throw ResearchSshException('无法连接 ${profile.host}:${profile.port}');
    }

    List<SSHKeyPair> identities = const [];
    if (profile.authType == SshAuthType.privateKey) {
      final pem = privateKeyPem?.trim() ?? '';
      if (pem.isEmpty) {
        await socket.close();
        throw ResearchSshException('未配置私钥');
      }
      try {
        identities = SSHKeyPair.fromPem(pem, passphrase);
      } catch (_) {
        await socket.close();
        throw ResearchSshException('私钥无效或口令错误');
      }
    }

    final trusted = profile.trustedHostKeyFingerprint?.trim();

    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: profile.authType == SshAuthType.password
          ? () => password
          : null,
      onVerifyHostKey: (type, fingerprintBytes) async {
        final fp = utf8.decode(fingerprintBytes);
        _lastFp = fp;
        final info = ResearchHostKeyInfo(fingerprintSha256: fp, keyType: type);
        if (trusted == null || trusted.isEmpty) {
          return onHostKeyTrust(info);
        }
        if (trusted == fp) return true;
        return onHostKeyMismatch(info, trusted);
      },
    );

    try {
      await client.authenticated.timeout(connectTimeout);
    } on TimeoutException {
      client.close();
      throw ResearchSshException('认证超时');
    } catch (e) {
      client.close();
      final msg = e.toString().toLowerCase();
      if (msg.contains('hostkey') || msg.contains('host key')) {
        throw ResearchSshException('主机密钥验证失败或已取消');
      }
      if (msg.contains('auth')) {
        throw ResearchSshException('认证失败，请检查用户名/密码或私钥');
      }
      throw ResearchSshException('SSH 连接失败');
    }

    late final SSHSession shell;
    try {
      shell = await client.shell(
        pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows),
      );
    } catch (_) {
      client.close();
      throw ResearchSshException('无法启动远程 shell');
    }

    _client = client;
    _shell = shell;
    _connected = true;

    _subs.add(
      shell.stdout.listen((data) {
        _emitStdout(data);
      }, onError: (_) {}),
    );
    _subs.add(
      shell.stderr.listen((data) {
        _emitStderr(data);
      }, onError: (_) {}),
    );
    unawaited(
      shell.done
          .then((_) {
            _connected = false;
            if (!(_done?.isCompleted ?? true)) _done?.complete();
          })
          .catchError((_) {
            _connected = false;
            if (!(_done?.isCompleted ?? true)) _done?.complete();
          }),
    );
  }

  @override
  void write(List<int> data) {
    final shell = _shell;
    if (shell == null || !_connected) return;
    shell.write(Uint8List.fromList(data));
  }

  @override
  void resize({required int cols, required int rows}) {
    final shell = _shell;
    if (shell == null || !_connected) return;
    shell.resizeTerminal(cols, rows);
  }

  @override
  Future<String> runExec(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final client = _client;
    if (client == null || !_connected) {
      throw ResearchSshException('未连接');
    }
    try {
      final session = await client.execute(command);
      final out = BytesBuilder(copy: false);
      final err = BytesBuilder(copy: false);
      final stdoutSub = session.stdout.listen(out.add);
      final stderrSub = session.stderr.listen(err.add);
      try {
        await Future.wait<void>([
          stdoutSub.asFuture<void>(),
          stderrSub.asFuture<void>(),
          session.done,
        ]).timeout(timeout);
      } on TimeoutException {
        await stdoutSub.cancel();
        await stderrSub.cancel();
        session.close();
        throw ResearchSshException('远程命令执行超时');
      }
      final stdoutText = utf8.decode(out.takeBytes(), allowMalformed: true);
      final stderrText = utf8.decode(err.takeBytes(), allowMalformed: true);
      if (session.exitCode != null && session.exitCode != 0) {
        throw ResearchSshExecException(
          exitCode: session.exitCode,
          stdoutText: stdoutText,
          stderrText: stderrText,
        );
      }
      return stdoutText;
    } catch (e) {
      if (e is ResearchSshException) rethrow;
      throw ResearchSshException('远程命令执行失败');
    }
  }

  @override
  Future<void> disconnect() => _teardown(closeStreams: true);

  Future<void> _teardown({required bool closeStreams}) async {
    _connected = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _clearEarlyOutput();
    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
    if (!(_done?.isCompleted ?? true)) {
      _done?.complete();
    }
    if (closeStreams) {
      if (!_stdoutController.isClosed) await _stdoutController.close();
      if (!_stderrController.isClosed) await _stderrController.close();
    }
  }

  StreamController<List<int>> _newStdoutController() =>
      StreamController<List<int>>.broadcast(onListen: _flushEarlyStdout);

  StreamController<List<int>> _newStderrController() =>
      StreamController<List<int>>.broadcast(onListen: _flushEarlyStderr);

  void _emitStdout(List<int> data) {
    if (_stdoutController.isClosed) return;
    if (_stdoutController.hasListener) {
      _stdoutController.add(data);
      return;
    }
    final copy = Uint8List.fromList(data);
    _earlyStdout.add(copy);
    _earlyStdoutBytes += copy.length;
    _trimEarly(_earlyStdout, stdout: true);
  }

  void _emitStderr(List<int> data) {
    if (_stderrController.isClosed) return;
    if (_stderrController.hasListener) {
      _stderrController.add(data);
      return;
    }
    final copy = Uint8List.fromList(data);
    _earlyStderr.add(copy);
    _earlyStderrBytes += copy.length;
    _trimEarly(_earlyStderr, stdout: false);
  }

  void _flushEarlyStdout() {
    if (_stdoutController.isClosed || !_stdoutController.hasListener) return;
    for (final data in _earlyStdout) {
      _stdoutController.add(data);
    }
    _earlyStdout.clear();
    _earlyStdoutBytes = 0;
  }

  void _flushEarlyStderr() {
    if (_stderrController.isClosed || !_stderrController.hasListener) return;
    for (final data in _earlyStderr) {
      _stderrController.add(data);
    }
    _earlyStderr.clear();
    _earlyStderrBytes = 0;
  }

  void _trimEarly(List<List<int>> queue, {required bool stdout}) {
    var bytes = stdout ? _earlyStdoutBytes : _earlyStderrBytes;
    while (bytes > _maxEarlyStreamBytes && queue.isNotEmpty) {
      bytes -= queue.removeAt(0).length;
    }
    if (stdout) {
      _earlyStdoutBytes = bytes;
    } else {
      _earlyStderrBytes = bytes;
    }
  }

  void _clearEarlyOutput() {
    _earlyStdout.clear();
    _earlyStderr.clear();
    _earlyStdoutBytes = 0;
    _earlyStderrBytes = 0;
  }
}
