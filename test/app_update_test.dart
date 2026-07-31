import 'package:dio/dio.dart';
import 'package:expert_chat/domain/update/app_update.dart';
import 'package:expert_chat/domain/update/update_prefs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppUpdateChecker version compare', () {
    test('normalizes GitHub asset digests', () {
      expect(
        AppUpdateChecker.normalizeAssetSha256(
          'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      expect(AppUpdateChecker.normalizeAssetSha256('not-a-hash'), isNull);
      expect(AppUpdateChecker.normalizeAssetSha256(null), isNull);
    });

    test('normalizes tags and build metadata', () {
      expect(AppUpdateChecker.normalizeVersionForTest('v1.2.0'), '1.2.0');
      expect(AppUpdateChecker.normalizeVersionForTest('1.2.0+3'), '1.2.0');
      // Pre-release identifiers survive so 1.2.0-beta can order below 1.2.0.
      expect(
        AppUpdateChecker.normalizeVersionForTest('1.2.0-beta'),
        '1.2.0-beta',
      );
    });

    test('detects newer versions', () {
      expect(AppUpdateChecker.isNewerForTest('1.2.0', '1.1.0'), isTrue);
      expect(AppUpdateChecker.isNewerForTest('1.1.1', '1.1.0'), isTrue);
      expect(AppUpdateChecker.isNewerForTest('2.0.0', '1.9.9'), isTrue);
      expect(AppUpdateChecker.isNewerForTest('1.1.0', '1.1.0'), isFalse);
      expect(AppUpdateChecker.isNewerForTest('1.0.9', '1.1.0'), isFalse);
    });

    test('orders pre-releases below the matching release', () {
      expect(AppUpdateChecker.isNewerForTest('1.2.0', '1.2.0-beta.1'), isTrue);
      expect(AppUpdateChecker.isNewerForTest('1.2.0-beta.1', '1.2.0'), isFalse);
      expect(
        AppUpdateChecker.isNewerForTest('1.2.0-beta.2', '1.2.0-beta.1'),
        isTrue,
      );
      expect(
        AppUpdateChecker.isNewerForTest('1.2.0-beta.1', '1.2.0-beta.1'),
        isFalse,
      );
      expect(AppUpdateChecker.isNewerForTest('1.2.1-beta.1', '1.2.0'), isTrue);
    });
  });

  group('pickAsset', () {
    final assets = [
      {
        'name': 'expert-chat-android-armeabi-v7a-v1.5.0.apk',
        'browser_download_url': 'https://example/v7a.apk',
      },
      {
        'name': 'expert-chat-android-arm64-v1.5.0.apk',
        'browser_download_url': 'https://example/arm64.apk',
      },
      {
        'name': 'expert-chat-android-universal-v1.5.0.apk',
        'browser_download_url': 'https://example/uni.apk',
      },
      {
        'name': 'expert-chat-windows-x64-v1.5.0.zip',
        'browser_download_url': 'https://example/win.zip',
      },
    ];

    test('prefers arm64 APK for arm64 devices', () {
      final hit = AppUpdateChecker.pickAsset(
        assets,
        abiHint: 'arm64-v8a',
        platform: TargetPlatform.android,
      );
      expect(hit?.name, contains('arm64'));
      expect(hit?.url, 'https://example/arm64.apk');
    });

    test('falls back to universal when ABI unknown', () {
      final hit = AppUpdateChecker.pickAsset(
        assets,
        abiHint: '',
        platform: TargetPlatform.android,
      );
      expect(hit?.name, contains('universal'));
    });

    test('v7a device does not pick arm64-only release assets', () {
      final arm64Only = [
        {
          'name': 'expert-chat-android-arm64-v1.6.3.apk',
          'browser_download_url': 'https://example/arm64.apk',
        },
        {
          'name': 'expert-chat-windows-x64-v1.6.3.zip',
          'browser_download_url': 'https://example/win.zip',
        },
      ];
      final hit = AppUpdateChecker.pickAsset(
        arm64Only,
        abiHint: 'armeabi-v7a',
        platform: TargetPlatform.android,
      );
      expect(hit, isNull);
    });

    test('arm64 miss falls back only to universal not arbitrary apk', () {
      final mixed = [
        {
          'name': 'expert-chat-android-armeabi-v7a-v1.6.3.apk',
          'browser_download_url': 'https://example/v7a.apk',
        },
        {
          'name': 'expert-chat-android-universal-v1.6.3.apk',
          'browser_download_url': 'https://example/uni.apk',
        },
      ];
      // Unknown/empty ABI: universal only (not v7a).
      final hit = AppUpdateChecker.pickAsset(
        mixed,
        abiHint: '',
        platform: TargetPlatform.android,
      );
      expect(hit?.name, contains('universal'));
    });

    test('picks windows zip on Windows', () {
      final hit = AppUpdateChecker.pickAsset(
        assets,
        platform: TargetPlatform.windows,
      );
      expect(hit?.name, contains('windows'));
      expect(hit?.url, endsWith('.zip'));
    });

    test('picks the Linux AppImage, never the Android APK', () {
      final linuxAssets = [
        {
          'name': 'expert-chat-android-universal-v1.5.0.apk',
          'browser_download_url': 'https://example/uni.apk',
        },
        {
          'name': 'expert-chat-linux-x64-v1.5.0.AppImage',
          'browser_download_url': 'https://example/appimage',
        },
      ];
      final hit = AppUpdateChecker.pickAsset(
        linuxAssets,
        platform: TargetPlatform.linux,
      );
      expect(hit?.name, contains('AppImage'));
      expect(hit?.url, 'https://example/appimage');
    });

    test('Linux without a Linux asset resolves nothing (no APK fallback)', () {
      final apkOnly = [
        {
          'name': 'expert-chat-android-universal-v1.5.0.apk',
          'browser_download_url': 'https://example/uni.apk',
        },
      ];
      final hit = AppUpdateChecker.pickAsset(
        apkOnly,
        platform: TargetPlatform.linux,
      );
      expect(hit, isNull);
    });

    test('iOS resolves no asset (App Store updates)', () {
      final hit = AppUpdateChecker.pickAsset(
        assets,
        platform: TargetPlatform.iOS,
      );
      expect(hit, isNull);
    });
  });

  group('update check request', () {
    test('sets a connectTimeout so weak networks fail fast', () async {
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
      Duration? connectTimeout;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            connectTimeout = options.connectTimeout;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 404,
              ),
            );
          },
        ),
      );

      final result = await AppUpdateChecker(dio: dio).check(
        preferredAbi: 'arm64-v8a',
      );

      expect(result.hasUpdate, isFalse);
      expect(connectTimeout, isNotNull);
      expect(
        connectTimeout!.inMilliseconds,
        inInclusiveRange(10000, 15000),
      );
    });
  });

  group('UpdatePrefs', () {
    test('skip version suppresses only that version', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = UpdatePrefs(await SharedPreferences.getInstance());
      expect(prefs.shouldPrompt('1.6.0'), isTrue);
      await prefs.skipVersion('1.6.0');
      expect(prefs.shouldPrompt('1.6.0'), isFalse);
      expect(prefs.shouldPrompt('1.6.1'), isTrue);
      await prefs.clearSkipped();
      expect(prefs.shouldPrompt('1.6.0'), isTrue);
    });
  });
}
