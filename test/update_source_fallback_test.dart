import 'package:dio/dio.dart';
import 'package:expert_chat/domain/update/app_update.dart';
import 'package:expert_chat/domain/update/update_sources.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('configured Gitee metadata is tried after GitHub fails', () async {
    PackageInfo.setMockInitialValues(
      appName: 'test',
      packageName: 'test',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const source = UpdateSource(
      name: 'mirror',
      template: 'https://gitee.com/example/app/releases/download/{tag}/{file}',
    );
    expect(
      source.releaseApi,
      'https://gitee.com/api/v5/repos/example/app/releases/latest',
    );
    final requested = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested.add(options.uri.host);
            if (options.uri.host == 'api.github.com') {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionTimeout,
                ),
              );
            } else {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'tag_name': 'v2.0.0',
                    'body': 'Release notes',
                    'assets': {
                      'links': [
                        {
                          'name': 'app-android-arm64.apk',
                          'url':
                              'https://gitee.com/example/app/releases/download/v2.0.0/app-android-arm64.apk',
                        },
                      ],
                    },
                  },
                ),
              );
            }
          },
        ),
      );
    final result = await AppUpdateChecker(
      dio: dio,
      releaseApis: [source.releaseApi!],
    ).check(preferredAbi: 'arm64-v8a');
    expect(requested, ['api.github.com', 'gitee.com']);
    expect(result.hasUpdate, true);
    expect(result.assetName, 'app-android-arm64.apk');
    expect(result.releaseUrl, 'https://gitee.com/example/app/releases');
    expect(result.downloadUrl, startsWith('https://gitee.com/'));
  });
}
