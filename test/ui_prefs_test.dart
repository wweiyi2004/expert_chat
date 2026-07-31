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

  test('wrong-typed fields fall back individually instead of wholesale', () {
    // 单个字段类型损坏不应让整个 UiPrefs 回退默认(那样下次保存会覆盖写回全部默认)。
    final restored = UiPrefs.fromJson({
      'textScale': 123,
      'density': 'compact',
      'messageStyle': true,
      'contentWidth': [1, 2],
      'liveMarkdown': 'yes',
      'ttsSpeed': 9,
    });

    expect(restored.textScale, TextScalePref.medium);
    expect(restored.density, DensityPref.compact);
    expect(restored.messageStyle, MessageStylePref.bubble);
    expect(restored.contentWidth, ContentWidthPref.regular);
    expect(restored.liveMarkdown, isTrue);
    expect(restored.ttsSpeed, TtsSpeedPref.normal);
  });
}
