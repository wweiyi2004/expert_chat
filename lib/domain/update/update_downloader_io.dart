import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../platform/paths.dart';

/// Partial packages and HTTP validators survive pauses and application restarts.
class UpdateDownloader {
  UpdateDownloader({Dio? dio, this._directory}) : _dio = dio ?? Dio();
  final Dio _dio;
  final Directory? _directory;
  static final _active = <String>{};

  Future<String> download({
    required String url,
    String? fileName,
    String? expectedSha256,
    List<String> fallbackUrls = const [],
    void Function(String url)? onSourceChanged,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final name = (fileName ?? Uri.parse(url).pathSegments.last).replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );
    final dir = _directory ?? await _downloadDir();
    await dir.create(recursive: true);
    final safeName = name.isEmpty || name == '.' || name == '..'
        ? 'expert-chat-update.bin'
        : name;
    final target = File('${dir.path}${Platform.pathSeparator}$safeName');
    if (!_active.add(target.absolute.path)) {
      throw StateError('该安装包正在下载');
    }
    try {
      final part = File('${target.path}.part');
      final meta = File('${target.path}.part.json');
      final digest = expectedSha256?.trim().toLowerCase();
      if (digest != null &&
          digest.isNotEmpty &&
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw ArgumentError('无效的 SHA-256');
      }
      final hash = digest == null || digest.isEmpty ? null : digest;
      final identity = hash ?? url;
      Map<String, dynamic> saved = {};
      try {
        saved = Map<String, dynamic>.from(
          jsonDecode(await meta.readAsString()) as Map,
        );
      } catch (_) {
        /* Interrupted metadata requires a clean restart. */
      }
      if (saved['identity'] != identity) {
        if (await part.exists()) await part.delete();
        saved = {};
      }
      Object? lastError;
      for (final source in {url, ...fallbackUrls}) {
        onSourceChanged?.call(source);
        for (var attempt = 0; attempt < 3; attempt++) {
          if (cancelToken?.isCancelled ?? false) {
            throw cancelToken!.cancelError!;
          }
          try {
            var offset = await part.exists() ? await part.length() : 0;
            if (offset > 0 &&
                hash == null &&
                (saved['url'] != source || saved['validator'] == null)) {
              await part.delete();
              offset = 0;
            }
            final response = await _dio.get<ResponseBody>(
              source,
              cancelToken: cancelToken,
              options: Options(
                responseType: ResponseType.stream,
                headers: {
                  'Accept': '*/*',
                  'Accept-Encoding': 'identity',
                  'User-Agent': 'expert_chat-update-download',
                  if (offset > 0) 'Range': 'bytes=$offset-',
                  if (offset > 0 &&
                      saved['url'] == source &&
                      saved['validator'] != null)
                    'If-Range': saved['validator'],
                },
                sendTimeout: const Duration(seconds: 30),
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 45),
                followRedirects: true,
                validateStatus: (s) => s == 200 || s == 206 || s == 416,
              ),
            );
            final body = response.data!;
            if (response.statusCode == 416) {
              await body.stream.drain<void>();
              if (offset > 0 && hash != null && await _matches(part, hash)) {
                await _validatePackage(part, name);
                return await _promote(part, target, meta);
              }
              if (await part.exists()) await part.delete();
              saved = {};
              throw const FormatException('服务器要求重新下载');
            }
            var total =
                int.tryParse(response.headers.value('content-length') ?? '') ??
                -1;
            if (response.statusCode == 206) {
              final range = RegExp(
                r'^bytes (\d+)-(\d+)/(\d+)$',
              ).firstMatch(response.headers.value('content-range') ?? '');
              if (range == null ||
                  int.parse(range[1]!) != offset ||
                  int.parse(range[2]!) < offset ||
                  int.parse(range[2]!) >= int.parse(range[3]!)) {
                await body.stream.drain<void>();
                throw const FormatException('下载源返回了不匹配的续传范围');
              }
              total = int.parse(range[3]!);
            } else {
              offset = 0; // Range ignored or If-Range representation changed.
            }
            final etag = response.headers.value('etag');
            saved = {
              'identity': identity,
              'url': source,
              'validator': etag != null && !etag.startsWith('W/')
                  ? etag
                  : response.headers.value('last-modified'),
            };
            // Truncate before storing a new validator.
            final file = await part.open(
              mode: offset == 0 ? FileMode.write : FileMode.append,
            );
            var received = offset;
            try {
              await meta.writeAsString(jsonEncode(saved), flush: true);
              onProgress?.call(received, total);
              await for (final chunk in body.stream) {
                if (cancelToken?.isCancelled ?? false) {
                  throw cancelToken!.cancelError!;
                }
                await file.writeFrom(chunk);
                received += chunk.length;
                onProgress?.call(received, total);
              }
              await file.flush();
            } finally {
              await file.close();
            }
            if (cancelToken?.isCancelled ?? false) {
              throw cancelToken!.cancelError!;
            }
            if (received == 0 || (total >= 0 && received != total)) {
              throw const FormatException('下载尚未完整，下次将继续');
            }
            if (hash != null && !await _matches(part, hash)) {
              await part.delete();
              throw const FormatException('安装包 SHA-256 校验失败，重新下载');
            }
            try {
              await _validatePackage(part, name);
            } catch (_) {
              await part.delete();
              rethrow;
            }
            return await _promote(part, target, meta);
          } catch (error) {
            if (error is DioException && CancelToken.isCancel(error)) rethrow;
            lastError = error;
          }
        }
      }
      throw lastError ?? StateError('没有可用的下载源');
    } finally {
      _active.remove(target.absolute.path);
    }
  }

  static Future<bool> _matches(File file, String hash) async =>
      (await sha256.bind(file.openRead()).first).toString() == hash;

  static Future<void> _validatePackage(File file, String name) async {
    if (!name.toLowerCase().endsWith('.apk') &&
        !name.toLowerCase().endsWith('.zip')) {
      return;
    }
    final handle = await file.open();
    try {
      final bytes = await handle.read(4);
      if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
        throw const FormatException('下载文件不是有效的 APK/ZIP');
      }
    } finally {
      await handle.close();
    }
  }

  static Future<String> _promote(File part, File target, File meta) async {
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    if (await meta.exists()) await meta.delete();
    return target.path;
  }

  Future<Directory> _downloadDir() async {
    if (Platform.isAndroid) {
      final cache = await getTemporaryDirectory();
      return Directory('${cache.path}${Platform.pathSeparator}ota');
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {
      /* Fall back to cache. */
    }
    return getTemporaryDirectory();
  }
}
