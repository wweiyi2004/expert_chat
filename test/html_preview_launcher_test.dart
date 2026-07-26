import 'package:expert_chat/features/chat/widgets/html_preview_launcher_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('refuses the file:// external-browser fallback on Android', () async {
    // ACTION_VIEW with file:// throws FileUriExposedException on Android 7+,
    // so the launcher must fail fast with a actionable message instead.
    await expectLater(
      launchHtmlPreview('<p>hi</p>', fileName: 'x.html', forceAndroid: true),
      throwsA(isA<StateError>()),
    );
  });
}
