import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/ui_prefs.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

void main() {
  test('original fourteen palettes retain every stored palette color', () {
    const frozen = <ColorThemePref, List<Color>>{
      ColorThemePref.minimal: [
        Color(0xFF4D6BFE),
        Color(0xFF111827),
        Color(0xFFFFFFFF),
        Color(0xFF111827),
        Color(0xFF0F0F10),
        Color(0xFFECECEC),
        Color(0xFFF7F7F8),
        Color(0xFF1C1C1E),
        Color(0xFFF3F4F6),
        Color(0xFF26262A),
        Color(0xFFE5E7EB),
        Color(0xFF2C2C2E),
      ],
      ColorThemePref.inkTeal: [
        Color(0xFF1F5C6B),
        Color(0xFFC45C26),
        Color(0xFFF4F1EA),
        Color(0xFF1C2430),
        Color(0xFF121820),
        Color(0xFFE8EEF5),
        Color(0xFFFFFCF7),
        Color(0xFF1A222D),
        Color(0xFFEFEAE1),
        Color(0xFF232C38),
        Color(0xFFDDD4C6),
        Color(0xFF334155),
      ],
      ColorThemePref.ocean: [
        Color(0xFF2B6CB0),
        Color(0xFF0D9488),
        Color(0xFFF0F5FA),
        Color(0xFF1A2B3C),
        Color(0xFF0F1724),
        Color(0xFFE2EAF4),
        Color(0xFFF8FBFE),
        Color(0xFF172033),
        Color(0xFFE4EEF7),
        Color(0xFF1E2A40),
        Color(0xFFC9D9E8),
        Color(0xFF334155),
      ],
      ColorThemePref.forest: [
        Color(0xFF2F6B4F),
        Color(0xFFB45309),
        Color(0xFFF1F5F0),
        Color(0xFF1A2A20),
        Color(0xFF101814),
        Color(0xFFE4EEE7),
        Color(0xFFF8FBF7),
        Color(0xFF18241C),
        Color(0xFFE4EDE5),
        Color(0xFF223028),
        Color(0xFFC9D6CB),
        Color(0xFF3A4A40),
      ],
      ColorThemePref.rose: [
        Color(0xFFB04A6E),
        Color(0xFF7C3AED),
        Color(0xFFFAF5F7),
        Color(0xFF2A1820),
        Color(0xFF181218),
        Color(0xFFF2E6EC),
        Color(0xFFFFFBFC),
        Color(0xFF241820),
        Color(0xFFF3E6EB),
        Color(0xFF302028),
        Color(0xFFE4CCD6),
        Color(0xFF4A3540),
      ],
      ColorThemePref.violet: [
        Color(0xFF6B5B95),
        Color(0xFFDB2777),
        Color(0xFFF5F3F9),
        Color(0xFF1E1830),
        Color(0xFF14121C),
        Color(0xFFECE6F5),
        Color(0xFFFCFAFE),
        Color(0xFF1C1828),
        Color(0xFFEBE6F3),
        Color(0xFF282438),
        Color(0xFFD4CCE3),
        Color(0xFF403850),
      ],
      ColorThemePref.amber: [
        Color(0xFFB7791F),
        Color(0xFF0F766E),
        Color(0xFFFAF6EF),
        Color(0xFF2A2114),
        Color(0xFF16120C),
        Color(0xFFF2EADF),
        Color(0xFFFFFCF7),
        Color(0xFF221C14),
        Color(0xFFF1E8D8),
        Color(0xFF2E261C),
        Color(0xFFE0D2B8),
        Color(0xFF4A4030),
      ],
      ColorThemePref.slate: [
        Color(0xFF4A5568),
        Color(0xFF64748B),
        Color(0xFFF4F5F7),
        Color(0xFF1A1F2A),
        Color(0xFF111418),
        Color(0xFFE6EAF0),
        Color(0xFFFBFBFC),
        Color(0xFF1A1E24),
        Color(0xFFE8EAEE),
        Color(0xFF252A32),
        Color(0xFFD0D5DD),
        Color(0xFF3A4250),
      ],
      ColorThemePref.nord: [
        Color(0xFF5E81AC),
        Color(0xFF88C0D0),
        Color(0xFFECEFF4),
        Color(0xFF2E3440),
        Color(0xFF2E3440),
        Color(0xFFECEFF4),
        Color(0xFFE5E9F0),
        Color(0xFF3B4252),
        Color(0xFFD8DEE9),
        Color(0xFF434C5E),
        Color(0xFFC7D0DC),
        Color(0xFF4C566A),
      ],
      ColorThemePref.primer: [
        Color(0xFF0969DA),
        Color(0xFF1A7F37),
        Color(0xFFF6F8FA),
        Color(0xFF1F2328),
        Color(0xFF0D1117),
        Color(0xFFE6EDF3),
        Color(0xFFFFFFFF),
        Color(0xFF161B22),
        Color(0xFFEFF2F5),
        Color(0xFF21262D),
        Color(0xFFD0D7DE),
        Color(0xFF30363D),
      ],
      ColorThemePref.stripe: [
        Color(0xFF635BFF),
        Color(0xFF0A2540),
        Color(0xFFF6F9FC),
        Color(0xFF0A2540),
        Color(0xFF0A2540),
        Color(0xFFF6F9FC),
        Color(0xFFFFFFFF),
        Color(0xFF112B4A),
        Color(0xFFEEF2F7),
        Color(0xFF1A3658),
        Color(0xFFD6E0EB),
        Color(0xFF2D4A6F),
      ],
      ColorThemePref.graphite: [
        Color(0xFF007AFF),
        Color(0xFF5856D6),
        Color(0xFFF2F2F7),
        Color(0xFF1C1C1E),
        Color(0xFF000000),
        Color(0xFFF2F2F7),
        Color(0xFFFFFFFF),
        Color(0xFF1C1C1E),
        Color(0xFFE5E5EA),
        Color(0xFF2C2C2E),
        Color(0xFFD1D1D6),
        Color(0xFF3A3A3C),
      ],
      ColorThemePref.clay: [
        Color(0xFFC15F3C),
        Color(0xFF5C4033),
        Color(0xFFFAF6F2),
        Color(0xFF2C211C),
        Color(0xFF1A1412),
        Color(0xFFF5EDE6),
        Color(0xFFFFFBF7),
        Color(0xFF261C18),
        Color(0xFFF0E6DC),
        Color(0xFF322620),
        Color(0xFFDFD0C2),
        Color(0xFF4A3A32),
      ],
      ColorThemePref.solar: [
        Color(0xFF268BD2),
        Color(0xFFB58900),
        Color(0xFFFDF6E3),
        Color(0xFF657B83),
        Color(0xFF002B36),
        Color(0xFF93A1A1),
        Color(0xFFEEE8D5),
        Color(0xFF073642),
        Color(0xFFE6DFC8),
        Color(0xFF0A3F4C),
        Color(0xFFD3CBB3),
        Color(0xFF586E75),
      ],
    };
    for (final entry in frozen.entries) {
      final p = entry.value;
      for (final dark in [false, true]) {
        final prefs = UiPrefs(colorTheme: entry.key);
        final actual =
            (dark ? AppTheme.dark(prefs) : AppTheme.light(prefs)).colorScheme;
        expect(
          actual.primary,
          dark ? Color.lerp(p[0], Colors.white, .35) : p[0],
        );
        expect(
          actual.secondary,
          dark ? Color.lerp(p[1], Colors.white, .25) : p[1],
        );
        expect(actual.surface, p[dark ? 4 : 2]);
        expect(actual.onSurface, p[dark ? 5 : 3]);
        expect(actual.surfaceContainer, p[dark ? 7 : 6]);
        expect(actual.surfaceContainerHighest, p[dark ? 9 : 8]);
        expect(actual.outline, p[dark ? 11 : 10]);
      }
    }
  });
  test(
    'all palettes report contrast; art palettes meet 4.5 for every required pair',
    () {
      // Existing shortfalls are measured baselines, never silently excused as
      // accessible colors. Any regression fails, and exact palette colors above
      // stay frozen. This includes solar's documented exception and the additional
      // legacy failures found during this redesign.
      const legacyMinimum = <String, Map<String, double>>{
        'minimal/light': {
          'onSurface/surface': 17.739717004,
          'onSurfaceVariant/surface': 9.335887552,
          'onPrimary/primary': 4.330088377,
          'primary/surface': 4.330088377,
          'secondary/surface': 17.739717004,
        },
        'minimal/dark': {
          'onSurface/surface': 16.217136248,
          'onSurfaceVariant/surface': 11.219967700,
          'onPrimary/primary': 6.757101912,
          'primary/surface': 7.740110177,
          'secondary/surface': 2.434821566,
        },
        'inkTeal/light': {
          'onSurface/surface': 13.847634384,
          'onSurfaceVariant/surface': 8.311467241,
          'onPrimary/primary': 7.496179372,
          'primary/surface': 6.645484632,
          'secondary/surface': 3.794709381,
        },
        'inkTeal/dark': {
          'onSurface/surface': 15.272706122,
          'onSurfaceVariant/surface': 10.481674678,
          'onPrimary/primary': 5.623557477,
          'primary/surface': 5.484674484,
          'secondary/surface': 6.166297226,
        },
        'ocean/light': {
          'onSurface/surface': 13.161580579,
          'onSurfaceVariant/surface': 8.509660763,
          'onPrimary/primary': 5.419829074,
          'primary/surface': 4.941449572,
          'secondary/surface': 3.413771173,
        },
        'ocean/dark': {
          'onSurface/surface': 14.815150928,
          'onSurfaceVariant/surface': 10.526900864,
          'onPrimary/primary': 6.311333997,
          'primary/surface': 6.520327840,
          'secondary/surface': 6.803263909,
        },
        'forest/light': {
          'onSurface/surface': 13.653186681,
          'onSurfaceVariant/surface': 8.463065755,
          'onPrimary/primary': 6.293363943,
          'primary/surface': 5.711788687,
          'secondary/surface': 4.557579126,
        },
        'forest/dark': {
          'onSurface/surface': 15.207014172,
          'onSurfaceVariant/surface': 10.634798046,
          'onPrimary/primary': 6.038461106,
          'primary/surface': 6.126234999,
          'secondary/surface': 5.586267585,
        },
        'rose/light': {
          'onSurface/surface': 15.575589392,
          'onSurfaceVariant/surface': 8.686920400,
          'onPrimary/primary': 5.184300889,
          'primary/surface': 4.806301635,
          'secondary/surface': 5.283089242,
        },
        'rose/dark': {
          'onSurface/surface': 15.199507267,
          'onSurfaceVariant/surface': 10.875398783,
          'onPrimary/primary': 6.321091178,
          'primary/surface': 6.735470888,
          'secondary/surface': 5.110248888,
        },
        'violet/light': {
          'onSurface/surface': 15.523045057,
          'onSurfaceVariant/surface': 8.496406640,
          'onPrimary/primary': 5.906210450,
          'primary/surface': 5.363582410,
          'secondary/surface': 4.174282954,
        },
        'violet/dark': {
          'onSurface/surface': 15.183831453,
          'onSurfaceVariant/surface': 10.863106968,
          'onPrimary/primary': 6.234495160,
          'primary/surface': 6.567394045,
          'secondary/surface': 5.581925995,
        },
        'amber/light': {
          'onSurface/surface': 14.699963106,
          'onSurfaceVariant/surface': 8.658296340,
          'onPrimary/primary': 3.640656396,
          'primary/surface': 3.379483436,
          'secondary/surface': 5.080610741,
        },
        'amber/dark': {
          'onSurface/surface': 15.640287498,
          'onSurfaceVariant/surface': 10.979762786,
          'onPrimary/primary': 7.273522499,
          'primary/surface': 8.440905905,
          'secondary/surface': 5.527206866,
        },
        'slate/light': {
          'onSurface/surface': 15.118117949,
          'onSurfaceVariant/surface': 8.555981868,
          'onPrimary/primary': 7.525629426,
          'primary/surface': 6.898731059,
          'secondary/surface': 4.362422688,
        },
        'slate/dark': {
          'onSurface/surface': 15.295219164,
          'onSurfaceVariant/surface': 10.839799351,
          'onPrimary/primary': 5.713888409,
          'primary/surface': 5.782414792,
          'secondary/surface': 6.217199454,
        },
        'nord/light': {
          'onSurface/surface': 10.835925553,
          'onSurfaceVariant/surface': 8.097682541,
          'onPrimary/primary': 4.029355986,
          'primary/surface': 3.495851009,
          'secondary/surface': 1.735601521,
        },
        'nord/dark': {
          'onSurface/surface': 10.835925553,
          'onSurfaceVariant/surface': 7.314777152,
          'onPrimary/primary': 7.124611785,
          'primary/surface': 5.431455209,
          'secondary/surface': 7.520408424,
        },
        'primer/light': {
          'onSurface/surface': 14.839194581,
          'onSurfaceVariant/surface': 8.728349129,
          'onPrimary/primary': 5.192060988,
          'primary/surface': 4.877064145,
          'secondary/surface': 4.770670804,
        },
        'primer/dark': {
          'onSurface/surface': 16.016082891,
          'onSurfaceVariant/surface': 11.116507461,
          'onPrimary/primary': 6.211326429,
          'primary/surface': 6.756712338,
          'secondary/surface': 5.887648611,
        },
        'stripe/light': {
          'onSurface/surface': 14.704787341,
          'onSurfaceVariant/surface': 8.806162293,
          'onPrimary/primary': 4.696973674,
          'primary/surface': 4.445236854,
          'secondary/surface': 14.704787341,
        },
        'stripe/dark': {
          'onSurface/surface': 14.704787341,
          'onSurfaceVariant/surface': 9.139904611,
          'onPrimary/primary': 6.536771836,
          'primary/surface': 5.971791072,
          'secondary/surface': 2.231677864,
        },
        'graphite/light': {
          'onSurface/surface': 15.247942490,
          'onSurfaceVariant/surface': 8.327209240,
          'onPrimary/primary': 4.016975780,
          'primary/surface': 3.599857119,
          'secondary/surface': 5.062968459,
        },
        'graphite/dark': {
          'onSurface/surface': 18.819381455,
          'onSurfaceVariant/surface': 12.335599162,
          'onPrimary/primary': 6.733497670,
          'primary/surface': 8.513003487,
          'secondary/surface': 6.125023680,
        },
        'clay/light': {
          'onSurface/surface': 14.558812326,
          'onSurfaceVariant/surface': 8.708943165,
          'onPrimary/primary': 4.225672026,
          'primary/surface': 3.929727398,
          'secondary/surface': 8.733144742,
        },
        'clay/dark': {
          'onSurface/surface': 15.735665112,
          'onSurfaceVariant/surface': 10.717329127,
          'onPrimary/primary': 6.828297977,
          'primary/surface': 7.477973157,
          'secondary/surface': 3.896659939,
        },
        'solar/light': {
          'onSurface/surface': 4.129605891,
          'onSurfaceVariant/surface': 8.679633822,
          'onPrimary/primary': 3.680278447,
          'primary/surface': 3.411801516,
          'secondary/surface': 2.975393601,
        },
        'solar/dark': {
          'onSurface/surface': 5.614162720,
          'onSurfaceVariant/surface': 8.839052020,
          'onPrimary/primary': 7.157566686,
          'primary/surface': 6.653121187,
          'secondary/surface': 6.438649497,
        },
      };
      final results = <String, Object>{};
      for (final palette in ColorThemePref.values) {
        for (final dark in [false, true]) {
          final prefs = UiPrefs(colorTheme: palette);
          final colors =
              (dark ? AppTheme.dark(prefs) : AppTheme.light(prefs)).colorScheme;
          final pairs = {
            'onSurface/surface': contrast(colors.onSurface, colors.surface),
            'onSurfaceVariant/surface': contrast(
              colors.onSurfaceVariant,
              colors.surface,
            ),
            'onPrimary/primary': contrast(colors.onPrimary, colors.primary),
            'primary/surface': contrast(colors.primary, colors.surface),
            'secondary/surface': contrast(colors.secondary, colors.surface),
          };
          results['${palette.name}/${dark ? 'dark' : 'light'}'] = pairs;
          if (!palette.isArt) {
            final key = '${palette.name}/${dark ? 'dark' : 'light'}';
            for (final pair in pairs.entries) {
              expect(
                pair.value + 0.000001,
                greaterThanOrEqualTo(
                  legacyMinimum[key]![pair.key]! < 4.5
                      ? legacyMinimum[key]![pair.key]!
                      : 4.5,
                ),
                reason: 'Legacy contrast must not regress: $key ${pair.key}',
              );
            }
          }
          if (palette.isArt) {
            for (final pair in pairs.entries) {
              expect(
                pair.value,
                greaterThanOrEqualTo(4.5),
                reason: '${palette.name} $dark ${pair.key}',
              );
            }
          }
        }
      }
      // Includes solar light's known 4.13:1 body contrast and every other legacy
      // shortfall. Legacy colors are frozen by the source snapshot test below.
      final report = File('output/redesign-review/contrast.json');
      report.parent.createSync(recursive: true);
      report.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(results),
      );
    },
  );
}
