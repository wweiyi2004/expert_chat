import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

Future<Map<String, dynamic>> executeMathScript(
  Map<String, dynamic> arguments, {
  required String pythonExecutable,
  required String trustedScript,
  CancelToken? cancelToken,
  Map<String, String>? childEnvironment,
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return {
      'ok': false,
      'code': 'platform_unavailable',
      'message': '手机未提供 Python/SymPy 运行时；请选用电脑执行端。',
    };
  }
  if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
  final payload = jsonEncode(arguments);
  if (utf8.encode(payload).length > 32768) {
    return {
      'ok': false,
      'code': 'request_too_large',
      'message': '数学请求超过 32 KiB',
    };
  }
  Process? process;
  Timer? timeout;
  var expired = false;
  var cancelled = false;
  try {
    process = await Process.start(
      pythonExecutable,
      ['-I', '-c', trustedScript],
      runInShell: false,
      includeParentEnvironment: false,
      environment: {
        ...Map<String, String>.from(childEnvironment ?? Platform.environment)
          ..removeWhere(
            (name, _) =>
                name.startsWith('EXPERT_REMOTE_') ||
                RegExp(
                  r'API_?KEY|TOKEN|SECRET|PASSWORD|^(HTTP|HTTPS|ALL)_PROXY$',
                  caseSensitive: false,
                ).hasMatch(name),
          ),
        'PYTHONIOENCODING': 'utf-8',
      },
    );
    final running = process;
    timeout = Timer(const Duration(seconds: 15), () {
      expired = true;
      running.kill();
    });
    unawaited(
      cancelToken?.whenCancel.then((_) {
        cancelled = true;
        running.kill();
      }),
    );
    // Continuously drain both pipes with a byte cap, rather than buffering an
    // unbounded worker response or deadlocking on a full stderr pipe.
    Future<String> bounded(Stream<List<int>> stream, int limit) async {
      final bytes = <int>[];
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > limit) {
          running.kill();
          throw StateError('数学后端输出超过上限');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    }

    final output = bounded(process.stdout, 110000);
    final errors = bounded(process.stderr, 8192);
    process.stdin.write(payload);
    await process.stdin.close();
    final results = await Future.wait<Object>([
      output,
      errors,
      process.exitCode,
    ]);
    if (cancelled || cancelToken?.isCancelled == true) {
      throw cancelToken!.cancelError!;
    }
    if (expired) {
      return {
        'ok': false,
        'code': 'timeout',
        'message': '数学运算超过 15 秒，已终止独立计算进程',
      };
    }
    if (results[2] != 0) {
      return {
        'ok': false,
        'code': 'worker_failed',
        'message': '数学进程失败，请检查 Python 与 SymPy 安装',
      };
    }
    return Map<String, dynamic>.from(jsonDecode(results[0] as String) as Map);
  } on ProcessException {
    return {
      'ok': false,
      'code': 'dependency_missing',
      'message':
          '未找到 Python。安装 Python 3，然后运行 python -m pip install sympy==1.14.0；应用不会自动安装。',
    };
  } finally {
    timeout?.cancel();
    process?.kill();
  }
}
