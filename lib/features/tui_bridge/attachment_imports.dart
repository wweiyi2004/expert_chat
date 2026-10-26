import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../core/providers.dart';
import '../../data/models.dart';
import '../../domain/tools/attachment_ingestor.dart';
import '../../domain/tools/file_parser.dart';
import '../../state/settings_controller.dart';
import 'protocol.dart';

class TuiAttachmentImports {
  TuiAttachmentImports(this.container);
  final ProviderContainer container;
  final _items =
      <
        String,
        ({
          String scope,
          String session,
          List<Attachment> values,
          DateTime expires,
        })
      >{};
  final _pending = <String, Set<CancelToken>>{};
  static const sourceExtensions = {
    'py',
    'rs',
    'dart',
    'js',
    'ts',
    'tsx',
    'jsx',
    'go',
    'c',
    'cc',
    'cpp',
    'cxx',
    'h',
    'hpp',
    'cs',
    'java',
    'kt',
    'kts',
    'swift',
    'sh',
    'bash',
    'zsh',
    'ps1',
    'bat',
    'cmd',
    'html',
    'htm',
    'css',
    'scss',
    'sass',
    'less',
    'vue',
    'svelte',
    'sql',
    'yaml',
    'yml',
    'toml',
    'ini',
    'conf',
    'cfg',
    'xml',
    'log',
    'tex',
    'ipynb',
    'r',
    'rb',
    'php',
    'lua',
    'm',
    'mm',
    'pl',
    'pm',
    'cmake',
    'gradle',
    'properties',
    'proto',
    'graphql',
    'gql',
    'gitignore',
    'gitattributes',
    'editorconfig',
    'dockerignore',
    'env',
    'lock',
  };
  static const sourceNames = {
    'dockerfile',
    'makefile',
    'gnumakefile',
    'cmakelists.txt',
    'readme',
    'license',
    'licence',
    'copying',
    'notice',
    'procfile',
    'gemfile',
    'rakefile',
    'justfile',
    '.gitignore',
    '.gitattributes',
    '.editorconfig',
    '.dockerignore',
    '.env',
    '.npmrc',
    '.yarnrc',
    '.bashrc',
    '.zshrc',
    '.profile',
  };
  static const audio = {
    'wav': 'audio/wav',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'flac': 'audio/flac',
    'opus': 'audio/opus',
  };
  static const video = {
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
  };
  String _key(String scope, String session) => jsonEncode([scope, session]);
  void cancel(String scope, String session) {
    for (final token in _pending[_key(scope, session)] ?? <CancelToken>{}) {
      token.cancel('用户取消附件导入');
    }
  }

  void release(String scope) {
    _items.removeWhere((_, item) => item.scope == scope);
    for (final entry in _pending.entries) {
      if ((jsonDecode(entry.key) as List).first == scope) {
        for (final token in entry.value) {
          token.cancel('附件来源连接已关闭');
        }
      }
    }
  }

  void consume(String scope, String session, Iterable<String> tokens) {
    for (final token in tokens) {
      final item = _items[token];
      if (item?.scope == scope && item?.session == session) {
        _items.remove(token);
      }
    }
  }

  List<Attachment> resolve(String scope, String session, String token) {
    _items.removeWhere((_, item) => item.expires.isBefore(DateTime.now()));
    final item = _items[token];
    if (item == null || item.scope != scope || item.session != session) {
      throw const BridgeFailure('not_found', '附件已过期或不属于此连接与会话，请重新选择文件');
    }
    return item.values;
  }

  Future<Map<String, Object?>> import(
    String scope,
    String session,
    Map<String, dynamic> params,
  ) async {
    if (params['confirmed'] != true) {
      throw const BridgeFailure('confirmation_required', '请明确确认所选本机文件');
    }
    final path = requiredString(params, 'path');
    if (!p.isAbsolute(path) || path.startsWith(r'\\.\')) {
      throw const BridgeFailure('invalid_params', '请选择本机普通文件的绝对路径');
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const BridgeFailure('invalid_params', '只支持普通文件，不能导入目录、链接或设备');
    }
    final file = File(await File(path).resolveSymbolicLinks());
    final stat = await file.stat();
    final name = p.basename(file.path),
        ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    final image = AttachmentIngestor.imageExtensions.contains(ext);
    final kind = audio.containsKey(ext)
        ? 'audio'
        : video.containsKey(ext)
        ? 'video'
        : image
        ? 'image'
        : 'file';
    final lowerName = name.toLowerCase();
    final sourceText =
        sourceExtensions.contains(ext) ||
        sourceNames.contains(lowerName) ||
        lowerName.startsWith('dockerfile.') ||
        lowerName.startsWith('makefile.');
    if (kind == 'file' &&
        !AttachmentIngestor.documentExtensions.contains(ext) &&
        !sourceText) {
      throw const BridgeFailure(
        'unsupported',
        '支持源码/配置文本、PDF、Office、常见图片、音频及视频；不支持可执行文件和未知二进制',
      );
    }
    final limit = switch (kind) {
      'audio' => 25 * 1024 * 1024,
      'video' => 100 * 1024 * 1024,
      'image' => 5 * 1024 * 1024,
      _ => 10 * 1024 * 1024,
    };
    if (stat.size <= 0 || stat.size > limit) {
      throw BridgeFailure(
        'too_large',
        '$kind 文件必须非空且不超过 ${limit ~/ 1024 ~/ 1024} MiB',
      );
    }
    final key = _key(scope, session);
    final token = CancelToken();
    (_pending[key] ??= <CancelToken>{}).add(token);
    final warnings = <String>[];
    final values = <Attachment>[];
    try {
      if (kind == 'audio') {
        final settings = await container.read(
          settingsControllerProvider.future,
        );
        if (!settings.asrConfigured) {
          throw const BridgeFailure(
            'configuration_required',
            '尚未配置语音识别接口；请先配置共享 ASR 服务再导入音频',
          );
        }
        final bytes = await FileParser.readBytesWithLimit(
          file.openRead(),
          maxBytes: limit,
        );
        if (token.isCancelled) throw token.cancelError!;
        final text = await container
            .read(mediaApiProvider)
            .transcribeSpeech(
              config: settings.asrApi,
              apiKey: settings.asrApiKey,
              audioBytes: bytes,
              mimeType: audio[ext]!,
              filename: name,
              cancelToken: token,
            );
        if (text.trim().isEmpty) {
          throw const BridgeFailure('parse_failed', '语音识别未返回可用文本，未附加空音频');
        }
        values.add(
          Attachment(
            name: name,
            mimeType: audio[ext]!,
            sizeBytes: stat.size,
            text: '【音频识别文本】\n$text',
          ),
        );
      } else if (kind == 'video') {
        values.addAll(await _video(file, name, video[ext]!, stat.size, token));
        warnings.add('已离线提取前60秒最多3个关键帧；未识别音轨，不代表完整视频内容。');
      } else {
        final result =
            await AttachmentIngestor(
              parser: container.read(fileParserProvider),
            ).ingest(
              [
                FileIngestSource(
                  name: name,
                  path: file.path,
                  extension: ext,
                  reportedSize: stat.size,
                ),
              ],
              slots: 1,
              existingBytes: 0,
              isCurrent: () => !token.isCancelled,
            );
        if (result.attachments.isEmpty) {
          throw const BridgeFailure('parse_failed', '无法解析此附件或超过支持的大小限制');
        }
        final attachment = result.attachments.single;
        if (attachment.parseError != null) {
          throw BridgeFailure('parse_failed', attachment.parseError!);
        }
        if (!attachment.hasImageData && attachment.text.trim().isEmpty) {
          throw const BridgeFailure('parse_failed', '文件没有可读取的文本或图像内容，未添加空标签');
        }
        values.add(attachment);
        if (attachment.truncated) warnings.add('提取文本超过60000字符，已按共享解析器限制截断。');
      }
      if (token.isCancelled) throw token.cancelError!;
      _items.removeWhere((_, item) => item.expires.isBefore(DateTime.now()));
      if (_items.values.where((item) => item.scope == scope).length >= 16) {
        throw const BridgeFailure('too_large', '本连接最多保留16次附件导入，请重连后重新选择或减少附件');
      }
      int retainedBytes(List<Attachment> attachments) => attachments.fold(
        0,
        (n, a) =>
            n +
            utf8.encode(a.text).length +
            ((a.imageBase64?.length ?? 0) * 3 ~/ 4),
      );
      final retained = _items.values
          .where((item) => item.scope == scope)
          .fold<int>(0, (n, item) => n + retainedBytes(item.values));
      if (retained + retainedBytes(values) > 48 * 1024 * 1024) {
        throw const BridgeFailure('too_large', '本连接待发送附件超过48 MiB，请先发送或减少附件');
      }
      final id = const Uuid().v4();
      _items[id] = (
        scope: scope,
        session: session,
        values: List.unmodifiable(values),
        expires: DateTime.now().add(const Duration(hours: 1)),
      );
      final preview = values.first.text;
      return {
        'token': id,
        'name': name,
        'mime': kind == 'video'
            ? video[ext]
            : kind == 'audio'
            ? audio[ext]
            : values.first.mimeType,
        'size': stat.size,
        'kind': kind,
        'preview': preview.runes.length > 300
            ? '${String.fromCharCodes(preview.runes.take(300))}…'
            : preview,
        'warnings': warnings,
        'attachments_count': values.length,
      };
    } on FormatException catch (error) {
      throw BridgeFailure('parse_failed', error.message.toString());
    } on FileReadLimitExceeded {
      throw const BridgeFailure('too_large', '导入期间文件增大，已停止读取');
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        throw const BridgeFailure('cancelled', '附件导入已取消');
      }
      throw const BridgeFailure('import_failed', '附件处理服务失败，请核对 ASR 配置与服务状态');
    } finally {
      _pending[key]?.remove(token);
      if (_pending[key]?.isEmpty == true) _pending.remove(key);
    }
  }

  Future<List<Attachment>> _video(
    File file,
    String name,
    String mime,
    int size,
    CancelToken token,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'expert-tui-video-',
    );
    Process? process;
    Timer? timer;
    try {
      try {
        process = await Process.start('ffmpeg', [
          '-nostdin',
          '-hide_banner',
          '-loglevel',
          'error',
          '-protocol_whitelist',
          'file,pipe',
          '-f',
          switch (p.extension(file.path).toLowerCase()) {
            '.avi' => 'avi',
            '.mkv' || '.webm' => 'matroska',
            _ => 'mov',
          },
          '-i',
          file.path,
          '-t',
          '60',
          '-vf',
          'fps=fps=1/20:start_time=0,scale=w=640:h=640:force_original_aspect_ratio=decrease',
          '-frames:v',
          '3',
          '-q:v',
          '5',
          p.join(directory.path, 'frame-%02d.jpg'),
        ], runInShell: false);
      } on ProcessException {
        throw const BridgeFailure(
          'dependency_missing',
          '未找到 ffmpeg。请安装并加入 PATH 后重新启动应用，再导入视频。',
        );
      }
      final current = process;
      unawaited(token.whenCancel.then((_) => current.kill()));
      timer = Timer(const Duration(seconds: 30), () => current.kill());
      final output = current.stdout.drain<void>(),
          errors = current.stderr.drain<void>();
      final code = await current.exitCode.timeout(
        const Duration(seconds: 35),
        onTimeout: () {
          current.kill();
          return -1;
        },
      );
      await Future.wait([output, errors]);
      if (token.isCancelled) throw const BridgeFailure('cancelled', '视频导入已取消');
      if (code != 0) {
        throw const BridgeFailure(
          'parse_failed',
          '视频抽帧失败或超过30秒处理时限，请检查文件格式或裁剪视频',
        );
      }
      final frames = await directory
          .list()
          .where((entry) => entry is File && p.extension(entry.path) == '.jpg')
          .cast<File>()
          .toList();
      frames.sort((a, b) => a.path.compareTo(b.path));
      if (frames.isEmpty) {
        throw const BridgeFailure('parse_failed', '视频没有可提取的图像帧');
      }
      final attachments = <Attachment>[
        Attachment(
          name: name,
          mimeType: mime,
          sizeBytes: size,
          text: '视频 $name：离线提取前60秒最多3帧，以下图像按时间顺序提供；未读取音轨。',
        ),
      ];
      final ingested =
          await AttachmentIngestor(
            parser: container.read(fileParserProvider),
          ).ingest(
            [
              for (final frame in frames.take(3))
                FileIngestSource(
                  name: '$name#${p.basename(frame.path)}',
                  extension: 'jpg',
                  path: frame.path,
                ),
            ],
            slots: 3,
            existingBytes: 0,
            isCurrent: () => !token.isCancelled,
          );
      if (ingested.attachments.isEmpty) {
        throw const BridgeFailure('parse_failed', '视频帧无法解码');
      }
      attachments.addAll(ingested.attachments);
      return attachments;
    } finally {
      timer?.cancel();
      process?.kill();
      try {
        final absolute = await directory.resolveSymbolicLinks(),
            base = await Directory.systemTemp.resolveSymbolicLinks();
        if (p.isWithin(base, absolute) &&
            p.basename(absolute).startsWith('expert-tui-video-')) {
          await directory.delete(recursive: true);
        }
      } catch (_) {
        /* Only best-effort cleanup of this import's own directory. */
      }
    }
  }
}
