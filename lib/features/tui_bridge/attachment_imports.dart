import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../core/providers.dart';
import '../../data/models.dart';
import '../../domain/tools/attachment_ingestor.dart';
import '../../domain/tools/file_parser.dart';
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
  static const audio = {
    'wav': 'audio/wav',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'flac': 'audio/flac',
    'opus': 'audio/opus',
    'amr': 'audio/amr',
    'weba': 'audio/webm',
    'wma': 'audio/x-ms-wma',
  };
  static const video = {
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    'avi': 'video/x-msvideo',
    'm4v': 'video/x-m4v',
    '3gp': 'video/3gpp',
  };
  String _key(String scope, String session) => jsonEncode([scope, session]);
  void cancel(String scope, String session) {
    for (final token in _pending[_key(scope, session)] ?? <CancelToken>{}) {
      token.cancel('用户取消附件导入');
    }
  }

  void release(String scope) {
    for (final file in _previewFiles.remove(scope) ?? <File>[]) {
      unawaited(
        Future<void>(() async {
          try {
            await file.delete();
            await file.parent.delete();
          } catch (_) {}
        }),
      );
    }
    _items.removeWhere((_, item) => item.scope == scope);
    for (final entry in _pending.entries) {
      if ((jsonDecode(entry.key) as List).first == scope) {
        for (final token in entry.value) {
          token.cancel('附件来源连接已关闭');
        }
      }
    }
  }

  void discardSession(String session) {
    _items.removeWhere((_, item) => item.session == session);
    for (final entry in _pending.entries) {
      if ((jsonDecode(entry.key) as List).last == session) {
        for (final token in entry.value) {
          token.cancel('空草稿已关闭');
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
    // A library file is stored under a UUID; its cosmetic display name is kept.
    final display = params['display_name'];
    final name = display is String && display.trim().isNotEmpty
            ? String.fromCharCodes(p.basename(display.trim()).runes.take(200))
            : p.basename(file.path),
        ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    final image = AttachmentIngestor.imageExtensions.contains(ext);
    final kind = audio.containsKey(ext)
        ? 'audio'
        : video.containsKey(ext)
        ? 'video'
        : image
        ? 'image'
        : 'file';
    // Non-image labels represent an address, never eagerly read file contents.
    // In particular, do not parse documents, transcribe audio or extract frames.
    if (!image) {
      return {
        'name': name,
        'path': file.path,
        'reference': true,
        'mime': audio[ext] ?? video[ext] ?? AttachmentIngestor.mimeFor(ext),
        'size': stat.size,
        'kind': kind,
        'preview': file.path,
        'warnings': <String>[],
        'attachments_count': 0,
      };
    }
    const limit = 5 * 1024 * 1024;
    if (stat.size <= 0 || stat.size > limit) {
      throw const BridgeFailure('too_large', '图片文件必须非空且不超过 5 MiB');
    }
    final key = _key(scope, session);
    final token = CancelToken();
    (_pending[key] ??= <CancelToken>{}).add(token);
    final warnings = <String>[];
    final values = <Attachment>[];
    try {
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
        'mime': values.first.mimeType,
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
      throw const BridgeFailure('import_failed', '图片导入失败，请重试');
    } finally {
      _pending[key]?.remove(token);
      if (_pending[key]?.isEmpty == true) _pending.remove(key);
    }
  }

  final _previewFiles = <String, List<File>>{};
  Future<void> preview(String scope, String session, String token) async {
    final values = resolve(scope, session, token);
    final image = values.where((a) => a.hasImageData).firstOrNull;
    if (image == null) throw const BridgeFailure('not_found', '图片数据不可用');
    final extension = switch (image.mimeType) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'png',
    };
    final directory = await Directory.systemTemp.createTemp(
      'expert-attachment-preview-',
    );
    final file = File(p.join(directory.path, 'preview.$extension'));
    await file.writeAsBytes(base64Decode(image.imageBase64!), flush: true);
    final files = _previewFiles.putIfAbsent(scope, () => []);
    files.add(file);
    if (files.length > 16) {
      final old = files.removeAt(0);
      try {
        await old.delete();
        await old.parent.delete();
      } catch (_) {}
    }
    final path = file.path;
    if (!Platform.isWindows) {
      throw const BridgeFailure('unsupported', '当前平台请使用文字预览');
    }
    await Process.start('explorer.exe', [
      path,
    ], mode: ProcessStartMode.detached);
  }
}
