import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads a full-package update asset (APK / zip) with progress callbacks.
class UpdateDownloader {
  UpdateDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// Download [url] into a local file named from the URL (or [fileName]).
  ///
  /// When [expectedSha256] is set (bare hex from GitHub `digest`), the file is
  /// hashed after download and deleted on mismatch.
  ///
  /// Returns the absolute path. On Android the file lives under the app cache
  /// so FileProvider can serve it for install. On desktop it prefers Downloads.
  Future<String> download({
    required String url,
    String? fileName,
    String? expectedSha256,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Web cannot download full-package updates in-app');
    }

    final name = (fileName ?? _nameFromUrl(url)).trim();
    final safeName = name.isEmpty
        ? 'expert-chat-update.bin'
        : name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    final dir = await _downloadDir();
    final file = File('${dir.path}${Platform.pathSeparator}$safeName');
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // Overwrite via dio anyway.
      }
    }

    await _dio.download(
      url,
      file.path,
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'Accept': '*/*',
          'User-Agent': 'expert_chat-update-download',
        },
        receiveTimeout: const Duration(minutes: 10),
        followRedirects: true,
        validateStatus: (s) => s != null && s >= 200 && s < 400,
      ),
      onReceiveProgress: (received, total) {
        if (onProgress != null) onProgress(received, total);
      },
    );

    if (!await file.exists() || await file.length() == 0) {
      throw Exception('下载完成但文件无效');
    }

    final expect = expectedSha256?.trim().toLowerCase();
    if (expect != null && expect.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      final actual = digest.toString();
      if (actual != expect) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception(
          '安装包校验失败（SHA-256 不匹配）。请从 GitHub 重新下载，或检查网络是否被篡改。',
        );
      }
    }

    // Cheap magic-byte check for our common artifacts.
    final lower = safeName.toLowerCase();
    if (lower.endsWith('.apk') || lower.endsWith('.zip')) {
      final raf = await file.open();
      try {
        final header = await raf.read(4);
        final isZip =
            header.length >= 2 && header[0] == 0x50 && header[1] == 0x4b;
        if (!isZip) {
          throw Exception('下载文件不是有效的 APK/ZIP 包装格式');
        }
      } finally {
        await raf.close();
      }
    }

    return file.path;
  }

  Future<Directory> _downloadDir() async {
    if (!kIsWeb && Platform.isAndroid) {
      final cache = await getTemporaryDirectory();
      final sub = Directory('${cache.path}${Platform.pathSeparator}ota');
      if (!await sub.exists()) await sub.create(recursive: true);
      return sub;
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } catch (_) {
      // Fall through.
    }
    return getTemporaryDirectory();
  }

  static String _nameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return 'expert-chat-update.bin';
    return uri.pathSegments.last;
  }
}
