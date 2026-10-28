import 'package:expert_chat/data/task_budget_prefs.dart';
import 'package:expert_chat/domain/chat/task_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'default task runs past old deadline and legacy default migrates',
    (tester) async {
      final reasons = <String>[];
      final prefs = TaskBudgetPrefs.fromJson({
        'preset': 'custom',
        'workSeconds': 900,
        'maxSearches': 192,
        'maxToolCalls': 192,
      });
      expect(prefs.workSeconds, 0);
      expect(
        TaskBudgetPrefs.fromJson(
          const TaskBudgetPrefs(workSeconds: 900).toJson(),
        ).workSeconds,
        900,
      );
      final budget = TaskBudget(prefs, onExhausted: reasons.add);
      await tester.pump(const Duration(hours: 3));
      expect(reasons, isEmpty);
      expect(budget.takeTool(), isTrue);
      budget.dispose();
    },
  );
  test(
    'all rounds share one tool/search allowance and exhaustion fires once',
    () {
      final reasons = <String>[];
      final budget = TaskBudget(
        const TaskBudgetPrefs(maxSearches: 1, maxToolCalls: 2),
        onExhausted: reasons.add,
      );
      addTearDown(budget.dispose);
      expect(budget.takeTool(), isTrue);
      expect(budget.takeSearch(), isTrue);
      budget.answerStarted();
      budget.resumeWork();
      expect(budget.takeTool(), isTrue);
      expect(budget.takeSearch(), isFalse);
      expect(budget.takeTool(), isFalse);
      budget.requestFinish('manual');
      expect(reasons, ['搜索次数已达上限']);
      expect(budget.toolCalls, 2);
    },
  );

  testWidgets('work deadline stops planning but not normal answer output', (
    tester,
  ) async {
    final reasons = <String>[];
    final first = TaskBudget(
      const TaskBudgetPrefs(workSeconds: 30),
      onExhausted: reasons.add,
    );
    await tester.pump(const Duration(seconds: 31));
    expect(reasons, ['任务执行时间已达上限']);
    first.dispose();
    reasons.clear();
    final second = TaskBudget(
      const TaskBudgetPrefs(workSeconds: 30),
      onExhausted: reasons.add,
    );
    second.answerStarted();
    await tester.pump(const Duration(minutes: 5));
    expect(reasons, isEmpty);
    second.dispose();
  });

  test('invalid preferences are bounded and old settings remain custom', () {
    expect(TaskBudgetPrefs.decode(null).preset, TaskBudgetPreset.custom);
    expect(
      TaskBudgetPrefs.decode('bad').maxToolCalls,
      TaskBudgetPrefs.unlimited,
    );
    final safe = TaskBudgetPrefs.fromJson({
      'workSeconds': -1,
      'maxSearches': 999,
      'maxToolCalls': 0,
    });
    expect(safe.workSeconds, 30);
    expect(safe.maxSearches, TaskBudgetPrefs.unlimited);
    expect(safe.maxToolCalls, 0);
  });

  test('tool and search counts are unlimited by default; legacy 192 too', () {
    expect(const TaskBudgetPrefs().maxToolCalls, TaskBudgetPrefs.unlimited);
    expect(const TaskBudgetPrefs().maxSearches, TaskBudgetPrefs.unlimited);
    final legacy = TaskBudgetPrefs.fromJson({
      'maxSearches': 192,
      'maxToolCalls': 192,
    });
    expect(legacy.maxToolCalls, TaskBudgetPrefs.unlimited);
    expect(legacy.maxSearches, TaskBudgetPrefs.unlimited);
    expect(TaskBudgetPrefs.fromJson({'maxToolCalls': 40}).maxToolCalls, 40);
    final roundTrip = TaskBudgetPrefs.fromJson(
      const TaskBudgetPrefs().toJson(),
    );
    expect(roundTrip.maxToolCalls, TaskBudgetPrefs.unlimited);
    expect(TaskBudgetPrefs.describeCount(TaskBudgetPrefs.unlimited), '不限');

    final reasons = <String>[];
    final budget = TaskBudget(
      const TaskBudgetPrefs(),
      onExhausted: reasons.add,
    );
    addTearDown(budget.dispose);
    for (var i = 0; i < 500; i++) {
      expect(budget.takeTool(), isTrue);
      expect(budget.takeSearch(), isTrue);
    }
    expect(reasons, isEmpty);
  });
}
