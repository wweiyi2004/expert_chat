import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../data/research/ssh_profile.dart';
import 'research_ssh_contract.dart';
import 'shell_quoting.dart';
import 'research_files.dart';
import 'research_files_io.dart';

export 'research_ssh_contract.dart';

ResearchSshClient createResearchSshClient() => ResearchSshClientIo();

/// Test seam mirroring [SSHClient]'s constructor: lets tests drive host-key,
/// auth and channel timing without a real SSH server.
typedef DebugSshClientFactory =
    SSHClient Function(
      SSHSocket socket, {
      required String username,
      required List<SSHKeyPair> identities,
      SSHPasswordRequestHandler? onPasswordRequest,
      SSHHostkeyVerifyHandler? onVerifyHostKey,
    });

class ResearchSshClientIo implements ResearchSshClient, ResearchFilesHost {
  @override
  ResearchFiles get files {
    final client = _client;
    if (client == null || !_connected) throw ResearchSshException('请先连接 SSH');
    return SshResearchFiles(client);
  }

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
  String? _interactiveTty;

  static const _ttyMarker = '\x1eexpert-chat-tty:';
  static final _interactiveShellCommand =
      '/bin/sh -c ${shellSingleQuote(r'''tty_value=$(tty) || exit; printf '\036expert-chat-tty:%s\037' "$tty_value"; exec "${SHELL:-/bin/sh}" -l''')}';

  static const _maxEarlyStreamBytes = 256 * 1024;

  /// For tests.
  @visibleForTesting
  DebugSshClientFactory? debugSshClientFactory;

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
  String? get interactiveTty => _interactiveTty;

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

    // Completes once the user has judged the host key. The trust dialog can
    // stay open as long as the user needs, so it must not count against the
    // auth timeout below.
    final hostKeyChecked = Completer<void>();

    final client = _buildClient(
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
        final bool ok;
        if (trusted == null || trusted.isEmpty) {
          ok = await onHostKeyTrust(info);
        } else if (trusted == fp) {
          ok = true;
        } else {
          ok = await onHostKeyMismatch(info, trusted);
        }
        if (!hostKeyChecked.isCompleted) hostKeyChecked.complete();
        return ok;
      },
    );

    try {
      // Wait for the fingerprint decision first: it can take longer than
      // connectTimeout while the user reads the dialog. If the connection
      // dies before the key is ever presented, surface that error instead of
      // waiting for a confirmation that can never come. Only the actual
      // authentication handshake is bounded by connectTimeout.
      await Future.any<void>([
        hostKeyChecked.future,
        client.authenticated.catchError((Object e) => throw e),
      ]);
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
      shell = await client
          .execute(
            _interactiveShellCommand,
            pty: SSHPtyConfig(
              type: 'xterm-256color',
              width: cols,
              height: rows,
            ),
          )
          .timeout(connectTimeout);
    } on TimeoutException {
      client.close();
      throw ResearchSshException('启动远程 shell 超时');
    } catch (_) {
      client.close();
      throw ResearchSshException('无法启动远程 shell');
    }

    _client = client;
    _shell = shell;
    final ttyReady = Completer<void>();
    var startupOutput = '';

    void failStartup() {
      if (!ttyReady.isCompleted) {
        ttyReady.completeError(ResearchSshException('远程终端在 TTY 初始化完成前关闭'));
      }
    }

    _subs.add(
      shell.stdout.listen(
        (data) {
          if (ttyReady.isCompleted) {
            _emitStdout(data);
            return;
          }
          // Latin-1 is a reversible byte mapping here, not a terminal text
          // decoder. UTF-8 characters may span packets around the marker.
          startupOutput += latin1.decode(data);
          final start = startupOutput.indexOf(_ttyMarker);
          if (start < 0) return;
          final end = startupOutput.indexOf('\x1f', start + _ttyMarker.length);
          if (end < 0) return;
          final tty = startupOutput.substring(start + _ttyMarker.length, end);
          if (!tty.startsWith('/dev/')) {
            ttyReady.completeError(ResearchSshException('远程终端未返回有效 TTY'));
            return;
          }
          _interactiveTty = tty;
          _emitStdout(
            latin1.encode(
              startupOutput.substring(0, start) +
                  startupOutput.substring(end + 1),
            ),
          );
          startupOutput = '';
          ttyReady.complete();
        },
        onError: (Object e) {
          // A channel error means the session is gone even if TCP is not.
          // Forward it through the same done-path the controller listens on —
          // swallowing it would leave the UI staring at a dead shell.
          debugPrint('research ssh stdout channel error: $e');
          failStartup();
          _markChannelClosed();
        },
      ),
    );
    _subs.add(
      shell.stderr.listen(
        (data) {
          _emitStderr(data);
        },
        onError: (Object e) {
          debugPrint('research ssh stderr channel error: $e');
          failStartup();
          _markChannelClosed();
        },
      ),
    );
    unawaited(
      shell.done
          .then((_) {
            failStartup();
            _markChannelClosed();
          })
          .catchError((_) {
            failStartup();
            _markChannelClosed();
          }),
    );
    try {
      await ttyReady.future.timeout(connectTimeout);
      if (_done!.isCompleted) throw ResearchSshException('远程终端已关闭');
      _connected = true;
    } on TimeoutException {
      await _teardown(closeStreams: false);
      throw ResearchSshException('获取远程终端 TTY 超时');
    } catch (_) {
      await _teardown(closeStreams: false);
      rethrow;
    }
  }

  /// The interactive channel is gone: tear down the connected state and
  /// complete [done] so upstream disconnects instead of hanging on a corpse.
  void _markChannelClosed() {
    _connected = false;
    _interactiveTty = null;
    if (!(_done?.isCompleted ?? true)) _done?.complete();
  }

  @override
  bool write(List<int> data) {
    final shell = _shell;
    if (shell == null || !_connected) return false;
    shell.write(Uint8List.fromList(data));
    return true;
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
      if (session.exitCode != 0) {
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

  SSHClient _buildClient(
    SSHSocket socket, {
    required String username,
    required List<SSHKeyPair> identities,
    SSHPasswordRequestHandler? onPasswordRequest,
    required SSHHostkeyVerifyHandler onVerifyHostKey,
  }) {
    final factory = debugSshClientFactory;
    if (factory != null) {
      return factory(
        socket,
        username: username,
        identities: identities,
        onPasswordRequest: onPasswordRequest,
        onVerifyHostKey: onVerifyHostKey,
      );
    }
    return SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: onPasswordRequest,
      onVerifyHostKey: onVerifyHostKey,
    );
  }

  Future<void> _teardown({required bool closeStreams}) async {
    _connected = false;
    _interactiveTty = null;
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
