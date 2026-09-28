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
      'markdownStyle': 0,
      'contentWidth': [1, 2],
      'liveMarkdown': 'yes',
      'ttsSpeed': 9,
    });

    expect(restored.textScale, TextScalePref.medium);
    expect(restored.density, DensityPref.compact);
    expect(restored.messageStyle, MessageStylePref.bubble);
    expect(restored.markdownStyle, MarkdownStylePref.standard);
    expect(restored.contentWidth, ContentWidthPref.regular);
    expect(restored.liveMarkdown, isTrue);
    expect(restored.ttsSpeed, TtsSpeedPref.normal);
  });

  test('markdownStyle round-trips and defaults to standard', () {
    final saved = const UiPrefs(
      markdownStyle: MarkdownStylePref.github,
    ).toJson();
    expect(UiPrefs.fromJson(saved).markdownStyle, MarkdownStylePref.github);
    expect(const UiPrefs().markdownStyle, MarkdownStylePref.standard);
  });

  test('legacy compact/article markdown styles map to the new skins', () {
    expect(MarkdownStylePref.fromWire('compact'), MarkdownStylePref.terminal);
    expect(MarkdownStylePref.fromWire('article'), MarkdownStylePref.notion);
  });

  group('2026-09 palette migration', () {
    test('new installs and unknown values use the minimal palette', () {
      expect(const UiPrefs().colorTheme, ColorThemePref.minimal);
      expect(ColorThemePref.fromWire('gone'), ColorThemePref.minimal);
    });

    test('an old save with the former default moves to minimal once', () {
      final migrated = UiPrefs.fromJson({'colorTheme': 'inkTeal'});
      expect(migrated.colorTheme, ColorThemePref.minimal);
      expect(migrated.toJson()['styleVersion'], UiPrefs.currentStyleVersion);
    });

    test('an explicit choice after the redesign is kept', () {
      final chosen = UiPrefs.fromJson({
        'colorTheme': 'inkTeal',
        'styleVersion': UiPrefs.currentStyleVersion,
      });
      expect(chosen.colorTheme, ColorThemePref.inkTeal);
      expect(
        UiPrefs.fromJson({'colorTheme': 'forest'}).colorTheme,
        ColorThemePref.forest,
      );
    });
  });
}
