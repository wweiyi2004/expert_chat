import 'package:expert_chat/data/ui_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'new reading defaults adopt design while old JSON preserves line height',
    () {
      expect(const UiPrefs().lineHeight, 1.7);
      expect(UiPrefs.fromJson(null).lineHeight, 1.7);
      expect(UiPrefs.fromJson({}).lineHeight, 1.85);
      expect(UiPrefs.fromJson({'lineHeight': 2.1}).lineHeight, 2.1);
    },
  );

  test(
    'redesign dimensions reject non-finite values and group copies are isolated',
    () {
      for (final value in [double.nan, double.infinity, '600', null]) {
        expect(UiPrefs.fromJson({'workbenchWidth': value}).workbenchWidth, 560);
      }
      expect(
        const UiPrefs()
            .copyWith(workbenchWidth: double.infinity)
            .workbenchWidth,
        560,
      );
      final groups = ['work:a', 'work:a'];
      final copied = const UiPrefs().copyWith(sidebarCollapsedGroups: groups);
      groups.add('chat:b');
      expect(copied.sidebarCollapsedGroups, ['work:a']);
      expect(
        () => copied.sidebarCollapsedGroups.add('mutate'),
        throwsUnsupportedError,
      );
      final encoded = copied.toJson();
      (encoded['sidebarCollapsedGroups'] as List).add('export-only');
      expect(copied.sidebarCollapsedGroups, ['work:a']);
    },
  );

  test(
    'redesign preferences preserve palettes, widths and collapsed groups',
    () {
      for (final palette in ColorThemePref.values) {
        final prefs = UiPrefs(
          colorTheme: palette,
          workbenchWidth: 720,
          sidebarCollapsedGroups: const ['work:local', 'chat:collection'],
        );
        final restored = UiPrefs.fromJson(prefs.toJson());
        expect(restored.colorTheme, palette);
        expect(restored.workbenchWidth, 720);
        expect(restored.sidebarCollapsedGroups, prefs.sidebarCollapsedGroups);
      }
      expect(UiPrefs.fromJson({}).workbenchWidth, 560);
      expect(
        UiPrefs.fromJson({'workbenchWidth': double.nan}).workbenchWidth,
        560,
      );
      expect(UiPrefs.fromJson({'workbenchWidth': 9999}).workbenchWidth, 900);
      expect(UiPrefs.fromJson({'workbenchWidth': 1}).workbenchWidth, 340);
      expect(
        UiPrefs.fromJson({
          'sidebarCollapsedGroups': [1, 'work:a', 'work:a'],
        }).sidebarCollapsedGroups,
        ['work:a'],
      );
      expect(
        UiPrefs.fromJson({'colorTheme': 'future-art'}).colorTheme,
        ColorThemePref.minimal,
      );
    },
  );

  test(
    'reading settings survive serialization with separate chat/work layouts',
    () {
      final chosen = const UiPrefs().copyWith(
        lineHeight: 2.1,
        paragraphSpacing: 14,
        messageSpacing: 30,
        messagePadding: 44,
        adaptiveMessagePadding: false,
        workContentWidth: ContentWidthPref.wide,
        workMessageStyle: MessageStylePref.bubble,
        popoverMaxHeight: 500,
        popoverTopMargin: 48,
      );
      final restored = UiPrefs.fromJson(chosen.toJson());
      expect(restored.toJson(), chosen.toJson());
      expect(restored.contentWidth, ContentWidthPref.regular);
      expect(restored.horizontalMessagePadding(1200), 44);
      expect(restored.horizontalMessagePadding(360), 24);
      final legacy = UiPrefs.fromJson({'colorTheme': 'forest'});
      expect(legacy.lineHeight, 1.85);
      expect(legacy.workMessageStyle, MessageStylePref.document);
      expect(legacy.workContentWidth, ContentWidthPref.full);
      expect(legacy.colorTheme, ColorThemePref.forest);
    },
  );
  test(
    'invalid reading values cannot break sliders or erase other preferences',
    () {
      final restored = UiPrefs.fromJson({
        'lineHeight': double.nan,
        'paragraphSpacing': -100,
        'messageSpacing': 999,
        'messagePadding': 'bad',
        'popoverMaxHeight': 9999,
        'density': 'compact',
      });
      expect(restored.lineHeight, 1.85);
      expect(restored.paragraphSpacing, 0);
      expect(restored.messageSpacing, 48);
      expect(restored.messagePadding, 32);
      expect(restored.popoverMaxHeight, 600);
      expect(restored.density, DensityPref.compact);
    },
  );
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
