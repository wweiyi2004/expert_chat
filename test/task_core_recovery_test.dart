import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:expert_chat/state/work_rounds.dart';
import 'package:expert_chat/state/session_policy.dart';
import 'package:expert_chat/domain/task_core/task_core.dart';
import 'package:expert_chat/domain/chat/task_budget.dart';
import 'package:expert_chat/data/task_budget_prefs.dart';

void main() {
  test('completed and cancelled histories never become resumable on load', () {
    final completed = TaskCore(rootId: 'completed');
    expect(
      TaskCore.fromJson(completed.toJson(), interrupted: false).resumeRequired,
      false,
    );
    completed.cancel();
    expect(TaskCore.fromJson(completed.toJson()).resumeRequired, false);
  });
  test(
    'round usage survives wake and continuation adds only requested rounds',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final rounds = container.read(workRoundsProvider.notifier);
      rounds.start('conversation', 'first', const SessionPolicy(toolRounds: 4));
      rounds.update('conversation', 'first', (p) => p.copyWith(used: 3));
      rounds.start(
        'conversation',
        'wake',
        const SessionPolicy(toolRounds: 24),
        preservePause: true,
      );
      expect(container.read(workRoundsProvider)['conversation']!.used, 3);
      expect(container.read(workRoundsProvider)['conversation']!.limit, 4);
      rounds.start(
        'conversation',
        'continue',
        const SessionPolicy(toolRounds: 24),
        restoredUsed: 3,
        restoredLimit: 4,
        extraRounds: 2,
      );
      expect(container.read(workRoundsProvider)['conversation']!.used, 3);
      expect(container.read(workRoundsProvider)['conversation']!.limit, 6);
    },
  );
  test(
    'restart retains lineage and inbox until durable context acknowledgement',
    () {
      final task = TaskCore(rootId: 'root', goal: 'original goal')
        ..lineage.add('assistant');
      task.receive('event', 'completion', 'assistant');
      final restored = TaskCore.fromJson(task.toJson());
      expect(restored.resumeRequired, true);
      expect(restored.goal, 'original goal');
      expect(restored.inbox['event']!['content'], 'completion');
      restored.acknowledge(['event']);
      expect(
        TaskCore.fromJson(
          restored.toJson(),
        ).receive('event', 'duplicate', 'assistant'),
        false,
      );
      restored.cancel();
      expect(restored.receive('late', 'late', 'assistant'), false);
    },
  );
  test('wakes restore cumulative tool and search debits', () {
    final first = TaskBudget(
      const TaskBudgetPrefs(maxToolCalls: 2, maxSearches: 1),
      onExhausted: (_) {},
    );
    expect(first.takeTool(), true);
    expect(first.takeSearch(), true);
    final saved = first.toJson();
    first.dispose();
    final next = TaskBudget(
      const TaskBudgetPrefs(maxToolCalls: 2, maxSearches: 1),
      snapshot: saved,
      onExhausted: (_) {},
    );
    expect(next.toolCalls, 1);
    expect(next.searches, 1);
    expect(next.takeTool(), true);
    expect(next.takeTool(), false);
    next.dispose();
  });
  test('root working continues after last child finishes', () {
    final task = TaskBudget(const TaskBudgetPrefs(), onExhausted: (_) {});
    task.childExecution(true);
    task.childExecution(false);
    expect(task.isWorking, true);
    task.dispose();
  });
  test('approval wait excludes root but retains active child work', () {
    final task = TaskBudget(const TaskBudgetPrefs(), onExhausted: (_) {});
    task.childExecution(true);
    task.waitForApproval();
    expect(task.isWorking, true);
    task.childExecution(false);
    expect(task.isWorking, false);
    task.dispose();
  });
  test(
    'child debit never resumes waiting root and all actors idle stop clock',
    () {
      final task = TaskBudget(const TaskBudgetPrefs(), onExhausted: (_) {});
      task.waitForApproval();
      task.takeTool(resumeRoot: false);
      expect(task.isWorking, false);
      task.childExecution(true);
      expect(task.isWorking, true);
      task.childExecution(false);
      expect(task.isWorking, false);
      task.dispose();
    },
  );
  test(
    'parallel children share one elapsed clock and approval idle excludes time',
    () async {
      final task = TaskBudget(const TaskBudgetPrefs(), onExhausted: (_) {});
      task.childExecution(true);
      task.childExecution(true);
      task.answerStarted();
      await Future<void>.delayed(const Duration(milliseconds: 35));
      task.childExecution(false);
      task.childExecution(false);
      final elapsed = task.toJson()['elapsedMs'] as int;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(task.toJson()['elapsedMs'], elapsed);
      expect(elapsed, lessThan(90));
      task.dispose();
    },
  );
}
