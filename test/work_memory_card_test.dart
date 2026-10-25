import 'package:expert_chat/features/workbench/logs/work_memory_card.dart';
import 'package:expert_chat/state/work_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'pin editor keeps draft after concurrent revision and disposes after dialog transition',
    (tester) async {
      final memory = WorkMemory(read: () => null, write: (s) async => true);
      await memory.checkpoint('c', {
        'expected_revision': 0,
        'user_pins': 'initial',
      }, userInitiated: true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [workMemoryProvider.overrideWithValue(memory)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (context) =>
                        const WorkMemoryEditDialog(conversationId: 'c'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'user draft retained');
      await memory.checkpoint('c', {
        'expected_revision': 1,
        'summary': 'model progressed',
      });
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('user draft retained'), findsOneWidget);
      expect(find.textContaining('版本已改变'), findsOneWidget);
      await tester.tap(find.text('刷新基线（保留草稿）'));
      await tester.pumpAndSettle();
      expect(find.text('user draft retained'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(memory.snapshot('c')['user_pins'], 'user draft retained');
      expect(memory.snapshot('c')['summary'], 'model progressed');
    },
  );
}
