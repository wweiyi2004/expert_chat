import 'package:expert_chat/domain/update/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
