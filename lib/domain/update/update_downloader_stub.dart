import 'package:dio/dio.dart';

/// Web stub — full-package OTA is desktop/mobile only.
class UpdateDownloader {
  UpdateDownloader({Dio? dio});

  Future<String> download({
    required String url,
    String? fileName,
    String? expectedSha256,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    throw UnsupportedError('Web cannot download full-package updates in-app');
  }
}
