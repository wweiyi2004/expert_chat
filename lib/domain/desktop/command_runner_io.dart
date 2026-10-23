import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'command_runner_contract.dart';

Future<String> runWorkspaceCommand(
  String command,
  String directory,
  Duration timeout,
  CancelToken token, {
  WorkspaceCommandOutput? onOutput,
  WorkspaceCommandCompletion? onComplete,
}) async {
  if (token.isCancelled) throw token.cancelError!;
  final process = await Process.start(
    Platform.isWindows ? 'powershell.exe' : '/bin/sh',
    Platform.isWindows
        ? [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '\$OutputEncoding = [Console]::OutputEncoding = [Console]::InputEncoding = [System.Text.UTF8Encoding]::new(\$false); $command',
          ]
        : ['-c', command],
    workingDirectory: directory,
    runInShell: false,
    environment: Platform.isWindows
        ? {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'}
        : null,
  );
  final out = StringBuffer(), err = StringBuffer();
  var truncated = false;
  void append(StringBuffer b, String text) {
    const limit = 64000;
    if (b.length >= limit) {
      truncated = true;
      return;
    }
    final remaining = limit - b.length;
    b.write(text.length > remaining ? text.substring(0, remaining) : text);
    if (text.length > remaining) truncated = true;
  }

  final output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen((v) {
        append(out, v);
        onOutput?.call(v, false);
      });
  final errors = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen((v) {
        append(err, v);
        onOutput?.call(v, true);
      });
  var stopped = false;
  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    if (Platform.isWindows) {
      await Process.run('taskkill.exe', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill();
    }
  }

  final outputDone = output.asFuture<void>(),
      errorsDone = errors.asFuture<void>();
  final done = process.exitCode.then((code) async {
    await Future.wait([outputDone, errorsDone]);
    return code;
  });
  final cancel = token.whenCancel.then((_) async {
    if (!stopped) await stop();
    return -1;
  });
  int exit;
  try {
    exit = await Future.any([done, cancel]).timeout(timeout);
  } on TimeoutException {
    await stop();
    onComplete?.call(const WorkspaceCommandOutcome(timedOut: true));
    return '命令超时，已请求终止本机进程。\n$out\n$err';
  } finally {
    stopped = true;
    await output.cancel();
    await errors.cancel();
  }
  onComplete?.call(
    WorkspaceCommandOutcome(
      exitCode: exit == -1 && token.isCancelled ? null : exit,
      cancelled: token.isCancelled,
    ),
  );
  return '退出码：$exit${token.isCancelled ? '（已取消）' : ''}\n$out${err.isEmpty ? '' : '\n标准错误：\n$err'}${truncated ? '\n输出过长，仅展示前 64000 字符。' : ''}';
}
