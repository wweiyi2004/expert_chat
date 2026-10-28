import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import '../../platform/foundation.dart';
import 'package:dio/dio.dart';

import '../../data/research/ssh_profile.dart';
import 'research_ssh_contract.dart';
import 'shell_quoting.dart';
import 'research_files.dart';
import 'research_files_io.dart';
import 'command_output_buffer.dart';
import 'ssh_remote_forwarding.dart';
import '../workbench/terminal/terminal_connection.dart';

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

class ResearchSshClientIo
    implements
        ResearchSshClient,
        ResearchFilesHost,
        ResearchCommandHost,
        ResearchTerminalHost {
  @override
  Future<TerminalConnection> openTerminal(
    String root,
    int columns,
    int rows,
  ) async {
    final client = _client;
    if (client == null || !_connected) throw ResearchSshException('请先连接 SSH');
    final command =
        'cd ${shellSingleQuote(root)} && exec "\${SHELL:-/bin/sh}" -l';
    final shell = await client.execute(
      command,
      pty: SSHPtyConfig(width: columns, height: rows, type: 'xterm-256color'),
    );
    return _WorkspaceSshTerminal(shell);
  }

  @override
  ResearchFiles get files {
    final client = _client;
    if (client == null || !_connected) throw ResearchSshException('请先连接 SSH');
    return SshResearchFiles(client);
  }

  SSHClient? _client;
  SSHSession? _shell;
  SshRemoteForwarding? _forwarding;
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
    final connectionDone = Completer<void>();
    _done = connectionDone;
    _lastFp = null;

    Future<T> whileConnecting<T>(Future<T> work) => Future.any<T>([
      work,
      connectionDone.future.then<T>((_) {
        throw ResearchSshException('连接已取消');
      }),
    ]);

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
    if (connectionDone.isCompleted) {
      await socket.close();
      throw ResearchSshException('连接已取消');
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
    final hostKeyReceived = Completer<void>();
    final hostKeyChecked = Completer<void>();

    final client = _buildClient(
      socket,
      username: profile.username,
      identities: identities,
      onPasswordRequest: profile.authType == SshAuthType.password
          ? () => password
          : null,
      onVerifyHostKey: (type, fingerprintBytes) async {
        if (connectionDone.isCompleted) return false;
        if (!hostKeyReceived.isCompleted) hostKeyReceived.complete();
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
        return ok && !connectionDone.isCompleted;
      },
    );
    // disconnect() must also own and close an unauthenticated transport.
    _client = client;

    var awaitingHostKey = true;
    try {
      // Bound the network wait before the trust dialog, but allow the user
      // to read that dialog without spending the authentication timeout.
      await whileConnecting(
        Future.any<void>([hostKeyReceived.future, client.authenticated]),
      ).timeout(connectTimeout);
      awaitingHostKey = false;
      await whileConnecting(
        Future.any<void>([hostKeyChecked.future, client.authenticated]),
      );
      await whileConnecting(client.authenticated).timeout(connectTimeout);
    } on TimeoutException {
      client.close();
      await socket.close();
      if (identical(_client, client)) _client = null;
      throw ResearchSshException(awaitingHostKey ? 'SSH 握手超时' : '认证超时');
    } catch (e) {
      client.close();
      await socket.close();
      if (identical(_client, client)) _client = null;
      if (e is ResearchSshException) rethrow;
      final msg = e.toString().toLowerCase();
      if (msg.contains('hostkey') || msg.contains('host key')) {
        throw ResearchSshException('主机密钥验证失败或已取消');
      }
      if (msg.contains('auth')) {
        throw ResearchSshException('认证失败，请检查用户名/密码或私钥');
      }
      throw ResearchSshException('SSH 连接失败');
    }

    if (profile.remoteForwards.isNotEmpty) {
      final forwarding = SshRemoteForwarding(
        onError: (message) => _emitStderr(utf8.encode('\r\n$message\r\n')),
      );
      _forwarding = forwarding;
      try {
        await whileConnecting(
          forwarding.start(
            client,
            profile.remoteForwards,
            timeout: connectTimeout,
          ),
        );
      } catch (error) {
        await _teardown(closeStreams: false);
        if (error is TimeoutException) {
          throw ResearchSshException('RemoteForward 建立超时');
        }
        rethrow;
      }
    }
    late final SSHSession shell;
    try {
      shell = await whileConnecting(
        client.execute(
          _interactiveShellCommand,
          pty: SSHPtyConfig(type: 'xterm-256color', width: cols, height: rows),
        ),
      ).timeout(connectTimeout);
    } on TimeoutException {
      await _forwarding?.close();
      _forwarding = null;
      client.close();
      await socket.close();
      if (identical(_client, client)) _client = null;
      throw ResearchSshException('启动远程 shell 超时');
    } catch (e) {
      await _forwarding?.close();
      _forwarding = null;
      client.close();
      await socket.close();
      if (identical(_client, client)) _client = null;
      if (e is ResearchSshException) rethrow;
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
      final clock = Stopwatch()..start();
      final session = await _openCommandChannel(client, command, timeout);
      final out = CommandOutputBuffer(maxChars: 2 * 1024 * 1024);
      final err = CommandOutputBuffer(maxChars: 2 * 1024 * 1024);
      final stdoutSub = decodeCommandOutput(
        session.stdout.cast<List<int>>(),
      ).listen(out.add);
      final stderrSub = decodeCommandOutput(
        session.stderr.cast<List<int>>(),
      ).listen(err.add);
      try {
        await Future.wait<void>([
          stdoutSub.asFuture<void>(),
          stderrSub.asFuture<void>(),
          session.done,
        ]).timeout(timeout - clock.elapsed);
      } on TimeoutException {
        throw ResearchSshException('远程命令执行超时');
      } finally {
        session.close();
        await stdoutSub.cancel();
        await stderrSub.cancel();
      }
      final stdoutText = out.text;
      final stderrText = err.text;
      if (session.exitCode != 0) {
        throw ResearchSshExecException(
          exitCode: session.exitCode,
          stdoutText: stdoutText,
          stderrText: stderrText,
        );
      }
      if (out.truncated || err.truncated) {
        throw ResearchSshException('SSH 查询输出超过 2 MiB，请缩小命令或目录查询范围。');
      }
      return stdoutText;
    } on TimeoutException {
      throw ResearchSshException('SSH 命令通道打开超时；远端执行状态需要核验。');
    } catch (e) {
      if (e is ResearchSshException) rethrow;
      throw ResearchSshException('远程命令执行失败');
    }
  }

  @override
  Future<String> runWorkspaceCommand(
    String command,
    Duration timeout,
    CancelToken token, {
    WorkspaceCommandOutput? onOutput,
    WorkspaceCommandCompletion? onComplete,
  }) async {
    final client = _client;
    if (client == null || !_connected) throw ResearchSshException('SSH 已断开');
    if (token.isCancelled) throw token.cancelError!;
    final clock = Stopwatch()..start();
    late final SSHSession session;
    try {
      session = await _openCommandChannel(
        client,
        command,
        timeout,
        token: token,
      );
    } on TimeoutException {
      onComplete?.call(const WorkspaceCommandOutcome(timedOut: true));
      throw ResearchSshException('SSH 命令通道打开超时；远端执行状态需要核验。');
    } catch (_) {
      if (token.isCancelled) {
        onComplete?.call(const WorkspaceCommandOutcome(cancelled: true));
      }
      rethrow;
    }
    final out = CommandOutputBuffer(),
        err = CommandOutputBuffer(maxChars: 8000);
    final live = CommandOutputBatch(onOutput);
    void collect(CommandOutputBuffer target, String text, bool isStderr) {
      target.add(text);
      live.add(text, isStderr);
    }

    final output = decodeCommandOutput(
      session.stdout.cast<List<int>>(),
    ).listen((v) => collect(out, v, false));
    final errors = decodeCommandOutput(
      session.stderr.cast<List<int>>(),
    ).listen((v) => collect(err, v, true));
    final finished = Future.wait<void>([
      output.asFuture<void>(),
      errors.asFuture<void>(),
      session.done,
    ]);
    var finishedWaiting = false;
    try {
      await Future.any([
        finished,
        token.whenCancel.then<void>((_) {
          if (finishedWaiting) return;
          session.close();
          onComplete?.call(const WorkspaceCommandOutcome(cancelled: true));
          throw ResearchSshException('已取消等待并关闭 SSH 通道；远端子进程状态需要核验。');
        }),
      ]).timeout(timeout - clock.elapsed);
      live.flush();
      final text = out.text, error = err.text;
      onComplete?.call(WorkspaceCommandOutcome(exitCode: session.exitCode));
      if (session.exitCode != 0) {
        throw ResearchSshExecException(
          exitCode: session.exitCode,
          stdoutText: text,
          stderrText: error,
        );
      }
      return '退出码：0\n$text${error.isEmpty ? '' : '\n标准错误：\n$error'}';
    } on TimeoutException {
      onComplete?.call(const WorkspaceCommandOutcome(timedOut: true));
      throw ResearchSshException('命令超时，已关闭 SSH 通道；远端子进程状态需要核验。');
    } finally {
      finishedWaiting = true;
      session.close();
      await output.cancel();
      await errors.cancel();
      live.flush();
    }
  }

  @override
  Future<void> disconnect() => _teardown(closeStreams: true);

  Future<SSHSession> _openCommandChannel(
    SSHClient client,
    String command,
    Duration timeout, {
    CancelToken? token,
  }) async {
    var abandoned = false;
    final opening = client.execute(command);
    unawaited(
      opening.then((session) {
        if (abandoned) session.close();
      }, onError: (Object _) {}),
    );
    try {
      return await Future.any<SSHSession>([
        opening,
        if (token != null)
          token.whenCancel.then<SSHSession>((error) => throw error),
      ]).timeout(timeout);
    } catch (_) {
      abandoned = true;
      rethrow;
    }
  }

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
    final forwarding = _forwarding;
    _forwarding = null;
    await forwarding?.close();
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

class _WorkspaceSshTerminal implements TerminalConnection {
  _WorkspaceSshTerminal(this.session) {
    var remaining = 2;
    void done() {
      if (--remaining == 0) _output.close();
    }

    _subscriptions.add(
      session.stdout.listen(
        _output.add,
        onError: _output.addError,
        onDone: done,
      ),
    );
    _subscriptions.add(
      session.stderr.listen(
        _output.add,
        onError: _output.addError,
        onDone: done,
      ),
    );
    _exitCode = session.done.then((_) {
      _exited = true;
      return session.exitCode;
    });
  }
  final SSHSession session;
  final _output = StreamController<List<int>>();
  final _subscriptions = <StreamSubscription<List<int>>>[];
  late final Future<int?> _exitCode;
  bool _closed = false, _exited = false;
  @override
  Stream<List<int>> get output => _output.stream;
  @override
  Future<int?> get exitCode => _exitCode;
  @override
  Future<void> write(List<int> bytes) async {
    if (!_closed && !_exited) session.write(Uint8List.fromList(bytes));
  }

  @override
  void resize(int columns, int rows) {
    if (!_closed && !_exited && columns > 0 && rows > 0) {
      session.resizeTerminal(columns, rows);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    session.close();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    await _output.close();
  }
}
