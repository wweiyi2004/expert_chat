import 'dart:io';

import 'package:dio/dio.dart';
import 'package:expert_chat/domain/update/update_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('update_downloader_test');
    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getDownloadsDirectory') return null;
      if (call.method == 'getTemporaryDirectory') {
        return '${root.path}${Platform.pathSeparator}tmp';
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  File partialFile() => File(
    '${root.path}${Platform.pathSeparator}tmp'
    '${Platform.pathSeparator}expert-chat-v2.1.0.apk',
  );

  test('cancel removes the partially downloaded file', () async {
    final downloader = UpdateDownloader(
      dio: _WritePartialThenThrowDio(
        DioException(
          requestOptions: RequestOptions(path: 'https://example/update.apk'),
          type: DioExceptionType.cancel,
          error: '用户取消',
        ),
      ),
    );

    await expectLater(
      downloader.download(
        url: 'https://example/update.apk',
        fileName: 'expert-chat-v2.1.0.apk',
      ),
      throwsA(isA<DioException>()),
    );

    // 取消后残留的半成品文件必须被清理,而不是留在下载目录。
    await _expectFileGone(partialFile());
  });

  test('a failed download does not leave a partial file behind', () async {
    final downloader = UpdateDownloader(
      dio: _WritePartialThenThrowDio(
        DioException(
          requestOptions: RequestOptions(path: 'https://example/update.apk'),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
    );

    await expectLater(
      downloader.download(
        url: 'https://example/update.apk',
        fileName: 'expert-chat-v2.1.0.apk',
      ),
      throwsA(isA<DioException>()),
    );

    await _expectFileGone(partialFile());
  });
}

/// Polls for the file to disappear. On Windows a freshly written file can be
/// transiently locked (antivirus scan), so a single immediate check is flaky
/// when the machine is under load; a broken cleanup still fails the poll.
Future<void> _expectFileGone(File file) async {
  for (var i = 0; i < 100; i++) {
    if (!file.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('partial file was not removed: ${file.path}');
}

/// Simulates an interrupted download: writes a partial file to [savePath] and
/// then throws without cleaning it up (the behavior of older dio releases).
class _WritePartialThenThrowDio with DioMixin implements Dio {
  _WritePartialThenThrowDio(this.error) {
    options = BaseOptions();
    httpClientAdapter = _UnusedAdapter();
  }

  final DioException error;

  @override
  Future<Response> download(
    String urlPath,
    dynamic savePath, {
    ProgressCallback? onReceiveProgress,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool deleteOnError = true,
    FileAccessMode fileAccessMode = FileAccessMode.write,
    String lengthHeader = Headers.contentLengthHeader,
    Object? data,
    Options? options,
  }) async {
    final file = File(savePath as String);
    await file.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    await raf.writeFrom([1, 2, 3]);
    await raf.close();
    throw error;
  }
}

/// Never reached: [_WritePartialThenThrowDio.download] throws before the
/// request pipeline runs, so this adapter only needs to satisfy the field.
class _UnusedAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    throw UnimplementedError();
  }
}
