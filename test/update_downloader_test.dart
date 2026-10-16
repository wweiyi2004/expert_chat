import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:expert_chat/domain/update/update_downloader.dart';
import 'package:expert_chat/domain/update/update_sources.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions) respond;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => respond(options);
}

void main() {
  late Directory root;
  final bytes = Uint8List.fromList([
    0x50,
    0x4b,
    3,
    4,
    ...List.generate(100, (i) => i),
  ]);
  final digest = sha256.convert(bytes).toString();
  setUp(() {
    root = Directory.systemTemp.createTempSync('expert-update-');
  });
  tearDown(() => root.deleteSync(recursive: true));
  Dio client(Future<ResponseBody> Function(RequestOptions) response) =>
      Dio()..httpClientAdapter = _Adapter(response);
  ResponseBody full([List<int>? data]) => ResponseBody.fromBytes(
    data ?? bytes,
    200,
    headers: {
      'content-length': ['${(data ?? bytes).length}'],
      'etag': ['"v1"'],
    },
  );
  Future<void> partial({String? hash}) async {
    final cancel = CancelToken();
    final dio = client(
      (_) async => ResponseBody(
        Stream.fromIterable([
          Uint8List.fromList(bytes.take(20).toList()),
          Uint8List.fromList(bytes.skip(20).toList()),
        ]),
        200,
        headers: {
          'content-length': ['${bytes.length}'],
          'etag': ['"v1"'],
        },
      ),
    );
    await expectLater(
      UpdateDownloader(dio: dio, directory: root).download(
        url: 'https://origin.test/app.apk',
        fileName: 'app.apk',
        expectedSha256: hash,
        cancelToken: cancel,
        onProgress: (count, _) {
          if (count >= 20) cancel.cancel('pause');
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(File('${root.path}/app.apk').existsSync(), false);
    expect(File('${root.path}/app.apk.part').lengthSync(), 20);
  }

  test('pause and a new downloader resume using Range and If-Range', () async {
    await partial(hash: digest);
    final requests = <RequestOptions>[];
    final progress = <int>[];
    final dio = client((r) async {
      requests.add(r);
      return ResponseBody.fromBytes(
        bytes.sublist(20),
        206,
        headers: {
          'content-range': ['bytes 20-${bytes.length - 1}/${bytes.length}'],
          'content-length': ['${bytes.length - 20}'],
          'etag': ['"v1"'],
        },
      );
    });
    final path = await UpdateDownloader(dio: dio, directory: root).download(
      url: 'https://origin.test/app.apk',
      fileName: 'app.apk',
      expectedSha256: digest,
      onProgress: (n, _) => progress.add(n),
    );
    expect(requests.single.headers['Range'], 'bytes=20-');
    expect(requests.single.headers['If-Range'], '"v1"');
    expect(progress.first, 20);
    expect(File(path).readAsBytesSync(), bytes);
    expect(File('$path.part').existsSync(), false);
  });
  test(
    'a server ignoring Range replaces partial bytes instead of appending',
    () async {
      await partial();
      final path = await UpdateDownloader(
        dio: client((_) async => full()),
        directory: root,
      ).download(url: 'https://origin.test/app.apk', fileName: 'app.apk');
      expect(File(path).readAsBytesSync(), bytes);
    },
  );
  test(
    'a failing origin falls back; unverified bytes never cross sources',
    () async {
      await partial();
      final mirrors = <RequestOptions>[];
      final dio = client((r) async {
        if (r.uri.host == 'origin.test') {
          return ResponseBody.fromString('unavailable', 503);
        }
        mirrors.add(r);
        return full();
      });
      final path = await UpdateDownloader(dio: dio, directory: root).download(
        url: 'https://origin.test/app.apk',
        fileName: 'app.apk',
        fallbackUrls: ['https://gitee.test/app.apk'],
      );
      expect(mirrors.single.headers.containsKey('Range'), false);
      expect(File(path).readAsBytesSync(), bytes);
    },
  );
  test('trusted hash permits resuming identical package on a mirror', () async {
    await partial(hash: digest);
    final dio = client((r) async {
      if (r.uri.host == 'origin.test') {
        return ResponseBody.fromString('unavailable', 503);
      }
      expect(r.headers['Range'], 'bytes=20-');
      expect(r.headers.containsKey('If-Range'), false);
      return ResponseBody.fromBytes(
        bytes.sublist(20),
        206,
        headers: {
          'content-range': ['bytes 20-${bytes.length - 1}/${bytes.length}'],
          'content-length': ['${bytes.length - 20}'],
        },
      );
    });
    final path = await UpdateDownloader(dio: dio, directory: root).download(
      url: 'https://origin.test/app.apk',
      fileName: 'app.apk',
      expectedSha256: digest,
      fallbackUrls: ['https://gitee.test/app.apk'],
    );
    expect(File(path).readAsBytesSync(), bytes);
  });
  test('bad checksum and HTML packages are never promoted', () async {
    for (final hash in [null, digest]) {
      final dio = client((_) async => full([60, 104, 116, 109, 108, 62]));
      await expectLater(
        UpdateDownloader(dio: dio, directory: root).download(
          url: 'https://origin.test/app.apk',
          fileName: 'app.apk',
          expectedSha256: hash,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(File('${root.path}/app.apk').existsSync(), false);
      expect(File('${root.path}/app.apk.part').existsSync(), false);
    }
  });
  test('mismatched content range is rejected without appending', () async {
    await partial(hash: digest);
    final dio = client(
      (_) async => ResponseBody.fromBytes(
        bytes,
        206,
        headers: {
          'content-range': ['bytes 0-${bytes.length - 1}/${bytes.length}'],
          'content-length': ['${bytes.length}'],
        },
      ),
    );
    await expectLater(
      UpdateDownloader(dio: dio, directory: root).download(
        url: 'https://origin.test/app.apk',
        fileName: 'app.apk',
        expectedSha256: digest,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(File('${root.path}/app.apk.part').lengthSync(), 20);
  });
  test(
    '416 only promotes a complete partial when its trusted hash matches',
    () async {
      await partial(hash: digest);
      File('${root.path}/app.apk.part').writeAsBytesSync(bytes);
      final path =
          await UpdateDownloader(
            directory: root,
            dio: client(
              (_) async => ResponseBody.fromString(
                '',
                416,
                headers: {
                  'content-range': ['bytes */${bytes.length}'],
                },
              ),
            ),
          ).download(
            url: 'https://origin.test/app.apk',
            fileName: 'app.apk',
            expectedSha256: digest,
          );
      expect(File(path).readAsBytesSync(), bytes);
    },
  );
  test(
    'source templates require HTTPS and version-specific asset identity',
    () {
      expect(
        UpdateSource.validate('http://example.test/{tag}/{file}'),
        isNotNull,
      );
      expect(UpdateSource.validate('https://example.test/{file}'), isNotNull);
      const source = UpdateSource(
        name: 'Gitee',
        template: 'https://gitee.com/owner/repo/releases/download/{tag}/{file}',
      );
      expect(UpdateSource.validate(source.template), isNull);
      expect(
        source.resolve(tag: 'v1.0', fileName: 'app arm64.apk', originalUrl: ''),
        contains('app%20arm64.apk'),
      );
    },
  );
}
