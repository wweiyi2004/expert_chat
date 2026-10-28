import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'paths_host.dart';

Map<String, dynamic> runMediaWorker(Map<String, Object?> request) {
  final program =
      Platform.environment['EXPERT_MEDIA_WORKER'] ??
      p.join(
        HostPaths.bundleDirectory,
        'expert-media-worker',
        'expert-media-worker.exe',
      );
  if (!p.isAbsolute(program) || !File(program).existsSync()) {
    throw StateError('独立文档/图像组件未安装，请使用包含 expert-media-worker 的完整发行包');
  }
  final temp = Directory.systemTemp.createTempSync('expert-media-request-');
  final input = File(p.join(temp.path, 'request.json'));
  try {
    final payload = utf8.encode(jsonEncode(request));
    if (payload.length > 24 * 1024 * 1024) throw StateError('媒体请求超出限制');
    input.writeAsBytesSync(payload, flush: true);
    final environment = <String, String>{
      for (final e in Platform.environment.entries)
        if (!RegExp(
          r'KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|EXPERT_REMOTE',
          caseSensitive: false,
        ).hasMatch(e.key))
          e.key: e.value,
    };
    final result = Process.runSync(
      program,
      [input.path],
      environment: environment,
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError('媒体组件失败或超时，退出码 ${result.exitCode}');
    }
    final output = result.stdout as String;
    if (output.length > 24 * 1024 * 1024) throw StateError('媒体输出超出限制');
    final decoded = jsonDecode(output);
    if (decoded is! Map || decoded['ok'] != true) {
      throw StateError('媒体组件无法处理该文件');
    }
    return Map<String, dynamic>.from(decoded);
  } finally {
    if (input.existsSync()) input.deleteSync();
    temp.deleteSync();
  }
}
