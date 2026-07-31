@TestOn('browser')
library;

import 'package:expert_chat/features/chat/widgets/html_preview_launcher_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PreviewUrlPolicy reuses one URL per document and rebuilds after revoke',
      () {
    final policy = PreviewUrlPolicy();
    expect(policy.needsNewUrlFor('<p>a</p>'), isTrue);
    policy.register('<p>a</p>', 'blob:one');
    expect(policy.needsNewUrlFor('<p>a</p>'), isFalse);
    expect(policy.needsNewUrlFor('<p>b</p>'), isTrue);
    expect(policy.url, 'blob:one');
    policy.revoke();
    expect(policy.url, isNull);
    expect(policy.needsNewUrlFor('<p>a</p>'), isTrue);
  });

  test('launchHtmlPreview reuses the object URL for the same document',
      () async {
    previewUrlPolicy.revoke();

    await launchHtmlPreview('<p>a</p>', fileName: 'a.html');
    final firstUrl = previewUrlPolicy.url;
    expect(firstUrl, isNotNull);
    expect(firstUrl, startsWith('blob:'));

    // Re-launching the same document must reuse the URL instead of minting
    // another blob URL (each with its own 1-minute auto-revoke timer).
    await launchHtmlPreview('<p>a</p>', fileName: 'a.html');
    expect(previewUrlPolicy.url, same(firstUrl));

    // A different document needs its own URL.
    await launchHtmlPreview('<p>b</p>', fileName: 'b.html');
    expect(previewUrlPolicy.url, isNot(same(firstUrl)));
  });
}
