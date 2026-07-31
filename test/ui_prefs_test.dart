import 'package:expert_chat/data/ui_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TTS speed round-trips without changing older defaults', () {
    final saved = const UiPrefs(ttsSpeed: TtsSpeedPref.fast).toJson();

    final restored = UiPrefs.fromJson(saved);
    expect(restored.ttsSpeed, TtsSpeedPref.fast);

    final legacy = UiPrefs.fromJson(const {'textScale': 'large'});
    expect(legacy.ttsSpeed, TtsSpeedPref.normal);
  });
}
