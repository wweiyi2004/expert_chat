import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import '../../../platform/services.dart';
import 'math_process.dart';
import 'package:path/path.dart' as p;
import '../../../platform/paths.dart';

bool get requiresRemoteMath => Platform.isAndroid || Platform.isIOS;

/// User-triggered only. Installs one fixed package into an app-owned venv;
/// model supplied package names, arguments and source URLs never enter here.
Future<Map<String, dynamic>> installManagedMath({
  required String pythonExecutable,
  CancelToken? cancelToken,
  void Function(String)? onStage,
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return {
      'ok': false,
      'code': 'platform_unavailable',
      'message': '手机没有本机 Python 安装器',
    };
  }
  final support = await getApplicationSupportDirectory();
  final environment = Directory(
    p.join(support.path, 'tools', 'math-sympy-1.14'),
  );
  if (await FileSystemEntity.isLink(environment.path)) {
    throw StateError('数学环境路径是符号链接，未安装');
  }
  final executable = p.join(
    environment.path,
    Platform.isWindows ? 'Scripts' : 'bin',
    Platform.isWindows ? 'python.exe' : 'python',
  );
  Future<void> run(String command, List<String> arguments) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final process = await Process.start(command, arguments, runInShell: false);
    var timedOut = false;
    final deadline = Timer(const Duration(minutes: 3), () {
      timedOut = true;
      process.kill();
    });
    unawaited(cancelToken?.whenCancel.then((_) => process.kill()));
    Future<void> drain(Stream<List<int>> stream) async {
      var count = 0;
      await for (final bytes in stream) {
        count += bytes.length;
        if (count > 1024 * 1024) {
          process.kill();
          throw StateError('安装输出超限');
        }
      }
    }

    try {
      final results = await Future.wait<Object?>([
        process.exitCode,
        drain(process.stdout),
        drain(process.stderr),
      ]);
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (timedOut) throw TimeoutException('数学依赖安装超过 3 分钟');
      if (results.first != 0) {
        throw StateError(
          '数学依赖安装失败；请检查 Python venv/pip、网络与 PyPI 访问，可使用复制命令手动安装',
        );
      }
    } finally {
      deadline.cancel();
      process.kill();
    }
  }

  onStage?.call('创建应用专用 Python 虚拟环境');
  if (!await File(executable).exists()) {
    await environment.parent.create(recursive: true);
    await run(pythonExecutable, ['-I', '-m', 'venv', environment.path]);
  }
  onStage?.call('从官方 PyPI 安装固定 SymPy 1.14.0');
  await run(executable, [
    '-I',
    '-m',
    'pip',
    '--isolated',
    '--disable-pip-version-check',
    'install',
    '--index-url',
    'https://pypi.org/simple',
    '--upgrade',
    'sympy==1.14.0',
  ]);
  final diagnostic = await executeMath(
    {'operation': 'diagnose'},
    pythonExecutable: executable,
    cancelToken: cancelToken,
  );
  return {...diagnostic, 'pythonExecutable': executable};
}

Future<Map<String, dynamic>> executeMath(
  Map<String, dynamic> arguments, {
  required String pythonExecutable,
  CancelToken? cancelToken,
}) async {
  if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
  final script = await rootBundle.loadString('assets/math/toolkit.py');
  return executeMathScript(
    arguments,
    pythonExecutable: pythonExecutable,
    trustedScript: script,
    cancelToken: cancelToken,
  );
}
