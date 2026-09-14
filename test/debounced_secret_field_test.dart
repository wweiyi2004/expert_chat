import 'package:expert_chat/features/settings/widgets/debounced_secret_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('saves only the settled secret and flushes on losing focus', (
    tester,
  ) async {
    final saves = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DebouncedSecretField(
                value: '',
                decoration: const InputDecoration(labelText: 'key'),
                onSaved: (value) async {
                  saves.add(value);
                },
              ),
              const TextField(decoration: InputDecoration(labelText: 'other')),
            ],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'sk-a');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, 'sk-final');
    await tester.pump(const Duration(milliseconds: 400));
    expect(saves, isEmpty);
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump();
    expect(saves, ['sk-final']);
    await tester.enterText(find.byType(TextField).first, 'sk-next');
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    expect(saves, ['sk-final', 'sk-next']);
  });

  testWidgets(
    'provider switch saves pending text to the old provider callback',
    (tester) async {
      final saves = <String>[];
      Future<void> pump(String id) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DebouncedSecretField(
              key: ValueKey(id),
              value: '$id-key',
              decoration: const InputDecoration(labelText: 'key'),
              onSaved: (value) async {
                saves.add('$id:$value');
              },
            ),
          ),
        ),
      );
      await pump('a');
      await tester.enterText(find.byType(TextField), 'new-a-key');
      await pump('b');
      await tester.pump();
      expect(saves, ['a:new-a-key']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'b-key',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
