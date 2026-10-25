import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/ui_prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

void main() {
  test(
    'actual ThemeData maps surface text and icons in every palette and brightness',
    () {
      for (final palette in ColorThemePref.values) {
        for (final dark in [false, true]) {
          final prefs = UiPrefs(colorTheme: palette);
          final theme = dark ? AppTheme.dark(prefs) : AppTheme.light(prefs);
          final scheme = theme.colorScheme;
          expect(theme.brightness, dark ? Brightness.dark : Brightness.light);
          for (final style in [
            theme.textTheme.titleLarge,
            theme.textTheme.titleMedium,
            theme.textTheme.bodyLarge,
            theme.textTheme.bodyMedium,
            theme.appBarTheme.titleTextStyle,
          ]) {
            expect(
              style!.color,
              scheme.onSurface,
              reason: '${palette.name}/$dark',
            );
            expect(
              _contrast(style.color!, scheme.surface),
              closeTo(_contrast(scheme.onSurface, scheme.surface), 1e-9),
            );
          }
          expect(theme.iconTheme.color, scheme.onSurfaceVariant);
          expect(
            theme.iconButtonTheme.style!.foregroundColor!.resolve({}),
            scheme.onSurfaceVariant,
          );
          expect(
            _contrast(theme.iconTheme.color!, scheme.surface),
            closeTo(_contrast(scheme.onSurfaceVariant, scheme.surface), 1e-9),
          );
        }
      }
    },
  );

  testWidgets(
    'rendered AppBar bottom, title, body and icons follow light-dark transitions',
    (tester) async {
      final mode = ValueNotifier(ThemeMode.dark);
      addTearDown(mode.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder<ThemeMode>(
          valueListenable: mode,
          builder: (_, value, _) => MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: value,
            home: Scaffold(
              appBar: AppBar(
                title: const Text('工作台标题'),
                bottom: const PreferredSize(
                  preferredSize: Size.fromHeight(40),
                  child: Text('会话标题', style: TextStyle(fontSize: 12.5)),
                ),
              ),
              body: const Column(
                children: [
                  Text('正文'),
                  Icon(Icons.folder_outlined, key: ValueKey('theme-icon')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final next in [ThemeMode.light, ThemeMode.dark, ThemeMode.light]) {
        mode.value = next;
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(find.text('正文')));
        for (final label in ['工作台标题', '会话标题', '正文']) {
          final rich = tester.widget<RichText>(
            find.descendant(
              of: find.text(label),
              matching: find.byType(RichText),
            ),
          );
          expect(
            rich.text.style!.color,
            theme.colorScheme.onSurface,
            reason: label,
          );
          expect(
            _contrast(rich.text.style!.color!, theme.colorScheme.surface),
            greaterThanOrEqualTo(4.5),
          );
        }
        final icon = tester.widget<RichText>(
          find.descendant(
            of: find.byKey(const ValueKey('theme-icon')),
            matching: find.byType(RichText),
          ),
        );
        expect(icon.text.style!.color, theme.colorScheme.onSurfaceVariant);
        expect(
          _contrast(icon.text.style!.color!, theme.colorScheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      }
    },
  );
}
