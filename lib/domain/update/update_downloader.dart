import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads a full-package update asset (APK / zip) with progress callbacks.
class UpdateDownloader {
  UpdateDownloader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  /// Download [url] into a local file named from the URL (or [fileName]).
  ///
  /// Returns the absolute path. On Android the file lives under the app cache
  /// so FileProvider can serve it for install. On desktop it prefers Downloads.
  Future<String> download({
    required String url,
    String? fileName,
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
