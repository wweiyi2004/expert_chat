import 'package:expert_chat/features/chat/widgets/html_preview_launcher_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewUrlPolicy', () {
    test('reuses one URL per document and rebuilds for a new one', () {
      final policy = PreviewUrlPolicy();
      expect(policy.needsNewUrlFor('<p>a</p>'), isTrue);
      policy.register('<p>a</p>', 'blob:one');
      expect(policy.needsNewUrlFor('<p>a</p>'), isFalse);
      expect(policy.needsNewUrlFor('<p>b</p>'), isTrue);
      expect(policy.url, 'blob:one');
    });

    test('revoke drops the URL so the next launch rebuilds it', () {
      final policy = PreviewUrlPolicy();
      policy.register('<p>a</p>', 'blob:one');
      policy.revoke();
      expect(policy.url, isNull);
      expect(policy.needsNewUrlFor('<p>a</p>'), isTrue);
      // pagehide + unload both fire — revoke must be idempotent.
      policy.revoke();
      expect(policy.needsNewUrlFor('<p>a</p>'), isTrue);
    });
  });
}
