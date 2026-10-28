import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// An opt-in companion, never a native subscription OAuth implementation.
/// Only user-configured executables and fixed, source-verified CLI flags enter
/// this launcher. Model requests cannot start/install/login to the companion.
class MagpieCompanion {
  Process? _process;
  int _apiPort = 3425, _webPort = 3430;
  String? _webKey;
  bool _exited = false;
  bool get owned => _process != null && !_exited;
  Future<void> _free(int port) async {
    if (port < 1024 || port > 65535) throw ArgumentError('端口须在 1024–65535');
    try {
      final socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      await socket.close();
    } on SocketException {
      throw StateError(
        '本机端口 $port 已被占用；不会接管或停止既有服务。可修改端口，或通过自定义 Base URL 连接已知服务。',
      );
    }
  }

  Future<bool> _ownsPort(int pid, int port) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('netstat', ['-ano', '-p', 'TCP']);
        return (result.stdout as String).split('\n').any((line) {
          final fields = line.trim().split(RegExp(r'\s+'));
          return fields.length >= 5 &&
              fields[0] == 'TCP' &&
              fields[1] == '127.0.0.1:$port' &&
              fields[3] == 'LISTENING' &&
              fields.last == '$pid';
        });
      }
      final result = await Process.run('lsof', [
        '-nP',
        '-iTCP:$port',
        '-sTCP:LISTEN',
        '-t',
      ]);
      return (result.stdout as String).split(RegExp(r'\s+')).contains('$pid');
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> start({
    required String executable,
    required String directory,
    int apiPort = 3425,
    int webPort = 3430,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError('请在电脑端启动 Magpie 伴随服务');
    }
    if (owned) throw StateError('本次启动的伴随服务仍在运行，不会热重启');
    if (executable.trim().isEmpty ||
        executable.contains('\n') ||
        !p.isAbsolute(executable)) {
      throw ArgumentError('请选择本机 Magpie 可执行文件的绝对路径（不含参数）');
    }
    if (!await File(executable).exists()) {
      throw StateError('Magpie 可执行文件不存在，请先从官方发行页安装');
    }
    final realExecutable = await File(executable).resolveSymbolicLinks();
    final beside = File(realExecutable).parent;
    if (await File(p.join(beside.path, '.portable')).exists() ||
        await Directory(p.join(beside.path, 'data')).exists()) {
      throw StateError(
        '所选 Magpie 邻近已有 portable/data 配置，会覆盖 XDG 隔离；请另选干净安装的 CLI，或显式连接现有网关',
      );
    }
    if (apiPort == webPort) throw ArgumentError('网关与管理页面端口不能相同');
    await _free(apiPort);
    await _free(webPort);
    final root = Directory(directory);
    await root.create(recursive: true);
    _webKey = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    _apiPort = apiPort;
    _webPort = webPort;
    _exited = false;
    final process = await Process.start(
      executable,
      ['web', '--gateway', '--addr', '127.0.0.1:$webPort', '--no-open'],
      runInShell: false,
      workingDirectory: root.path,
      environment: {
        'MAGPIE_ADDR': '127.0.0.1:$apiPort',
        'MAGPIE_WEB_KEY': _webKey!,
        'MAGPIE_NO_ACCOUNTS': '1',
        'DO_NOT_TRACK': '1',
        'MAGPIE_NO_STATS': '1',
        'XDG_CONFIG_HOME': p.join(root.path, 'config'),
        'XDG_CACHE_HOME': p.join(root.path, 'cache'),
      },
    );
    _process = process;
    // Output can contain the management key or upstream account details. Drain
    // it without copying any line to diagnostics, settings or model context.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) _exited = true;
      }),
    );
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        if (_exited) {
          throw StateError('Magpie 已退出，请检查版本、端口或安装；未读取伴随服务日志以免暴露登录资料');
        }
        try {
          final found = await models(apiPort: apiPort);
          if (await _ownsPort(process.pid, apiPort) &&
              await _ownsPort(process.pid, webPort)) {
            return found;
          }
        } catch (_) {
          /* Startup polling only, no model calls. */
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      throw StateError('伴随服务未在 20 秒内通过端口进程归属与模型目录检查；不会连接无关监听器');
    } catch (_) {
      await stopOwned();
      rethrow;
    }
  }

  Future<List<String>> models({int? apiPort}) async {
    if (apiPort == null &&
        (!owned || !await _ownsPort(_process!.pid, _apiPort))) {
      throw StateError('本次启动的网关进程已不持有 API 端口，未读取无关服务');
    }
    final port = apiPort ?? _apiPort;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 2),
        receiveTimeout: const Duration(seconds: 2),
        followRedirects: false,
      ),
    );
    try {
      final response = await dio.get<dynamic>(
        'http://127.0.0.1:$port/v1/models',
        options: Options(headers: {'Authorization': 'Bearer magpie'}),
      );
      final data = response.data;
      if (data is! Map || data['data'] is! List) {
        throw StateError('此端口未返回兼容模型目录');
      }
      return (data['data'] as List)
          .whereType<Map>()
          .map((m) => m['id'])
          .whereType<String>()
          .where((id) => id.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
    } finally {
      dio.close(force: true);
    }
  }

  Future<void> openManagement(Future<bool> Function(Uri) launch) async {
    if (!owned || _webKey == null) throw StateError('请先启动并验证本应用持有的伴随服务');
    if (!await _ownsPort(_process!.pid, _webPort)) {
      throw StateError('管理页面端口的进程归属已变化，未打开带密钥的链接');
    }
    if (!await launch(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: _webPort,
        path: '/',
        queryParameters: {'k': _webKey!},
      ),
    )) {
      throw StateError('无法打开系统浏览器');
    }
  }

  Future<void> stopOwned() async {
    final process = _process;
    _process = null;
    _webKey = null;
    if (process == null || _exited) return;
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    _exited = true;
  }
}
