import 'package:expert_chat/domain/update/app_update.dart';
import 'package:expert_chat/domain/update/update_prefs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AppUpdateChecker version compare', () {
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

    test('picks windows zip on Windows', () {
      final hit = AppUpdateChecker.pickAsset(
        assets,
        platform: TargetPlatform.windows,
      );
      expect(hit?.name, contains('windows'));
      expect(hit?.url, endsWith('.zip'));
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
