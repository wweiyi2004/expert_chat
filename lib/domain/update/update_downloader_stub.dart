import 'package:dio/dio.dart';

/// Web stub — full-package OTA is desktop/mobile only.
class UpdateDownloader {
  UpdateDownloader({Dio? dio, Object? directory});

  Future<String> download({
    required String url,
    String? fileName,
    String? expectedSha256,
    List<String> fallbackUrls = const [],
    void Function(String url)? onSourceChanged,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    throw UnsupportedError('Web cannot download full-package updates in-app');
  }
}
