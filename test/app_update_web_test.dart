@TestOn('browser')
library;

import 'package:dio/dio.dart';
import 'package:expert_chat/domain/update/app_update.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('web check is skipped: no HTTP request, no update prompt', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAll') {
        return {
          'appName': 'expert_chat',
          'packageName': 'com.example.expert_chat',
          'version': '1.0.0',
          'buildNumber': '1',
          'buildSignature': '',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final dio = Dio();
    var requests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          handler.next(options);
        },
      ),
    );

    // Web 部署由服务器更新,客户端检查被禁用 —— 不发请求、不提示更新。
    final result = await AppUpdateChecker(dio: dio).check();

    expect(requests, 0);
    expect(result.hasUpdate, isFalse);
  });

  test('web pickAsset resolves nothing (no APK fallback)', () {
    final hit = AppUpdateChecker.pickAsset([
      {
        'name': 'expert-chat-android-universal-v1.5.0.apk',
        'browser_download_url': 'https://example/uni.apk',
      },
    ]);
    expect(hit, isNull);
  });
}
