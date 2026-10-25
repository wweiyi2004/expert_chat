import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/core/theme.dart';
import 'package:expert_chat/data/ui_prefs.dart';
import 'package:expert_chat/features/settings/widgets/appearance_settings_widgets.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'palette picker keeps original and art choices at 360 wide dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        ColorThemePref? chosen;
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    ColorThemeLivePreview(
                      theme: ColorThemePref.dailan,
                      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                    ),
                    ColorThemePicker(
                      selected: ColorThemePref.minimal,
                      onSelected: (value) => chosen = value,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('艺术配色（中国传统色、和田三造《配色辞典》）'), findsOneWidget);
        expect(find.text('原有配色（14 套）'), findsOneWidget);
        await tester.ensureVisible(find.text(ColorThemePref.dailan.label).last);
        await tester.tap(find.text(ColorThemePref.dailan.label).last);
        expect(chosen, ColorThemePref.dailan);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
