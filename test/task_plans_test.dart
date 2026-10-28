import 'package:test/test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/platform/preferences.dart';
import 'package:expert_chat/state/task_plans.dart';
import 'package:expert_chat/data/task_data_backup.dart';

void main() {
  late ProviderContainer container;
  late TaskPlans plans;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(
          await SharedPreferences.getInstance(),
        ),
      ],
    );
    plans = container.read(taskPlansProvider.notifier);
  });
  tearDown(() => container.dispose());
  Future<TaskPlan> propose({bool review = true, int revision = 0}) =>
      plans.propose(
        conversation: 'c',
        goal: 'Fix parser',
        body: 'Read then repair parser',
        titles: ['Read', 'Repair'],
        expectedRevision: revision,
        requiresReview: review,
        target: {'root': 'original'},
        taskId: 'root-task',
      );
  test(
    'comments invalidate approval, stale versions cannot be approved',
    () async {
      final first = await propose();
      await plans.approve('c', first.revision, first.contentHash);
      final changed = await plans.comment(
        'c',
        first.revision,
        'Preserve old files',
      );
      expect(changed.revision, 2);
      expect(changed.approved, isFalse);
      await expectLater(
        plans.approve('c', first.revision, first.contentHash),
        throwsStateError,
      );
      final approved = await plans.approve(
        'c',
        changed.revision,
        changed.contentHash,
      );
      expect(approved.approved, isTrue);
      final revised = await propose(review: false, revision: 2);
      expect(revised.status, TaskPlanStatus.awaitingApproval);
    },
  );
  test('ordinary tracking does not insert a user approval gate', () async {
    final plan = await propose(review: false);
    expect(plan.status, TaskPlanStatus.tracking);
    final next = await plans.progress(
      'c',
      plan.revision,
      plan.steps.first.id,
      PlanStepStatus.completed,
      [],
      verified: false,
    );
    expect(next.steps.first.verified, isFalse);
    expect(next.requiresReview, isFalse);
  });
  test(
    'revising a plan preserves unchanged steps and completion records',
    () async {
      final first = await propose(review: false);
      await plans.progress(
        'c',
        first.revision,
        first.steps.first.id,
        PlanStepStatus.completed,
        ['tool-1'],
        verified: true,
      );
      final revised = await propose(review: false, revision: first.revision);
      expect(revised.steps.first.id, first.steps.first.id);
      expect(revised.steps.first.status, PlanStepStatus.completed);
      expect(revised.steps.first.evidence, ['tool-1']);
    },
  );
  test('serialized edits reject racing approval of an old version', () async {
    final plan = await propose();
    final editing = plans.comment('c', 1, 'New requirement');
    final approval = plans.approve('c', 1, plan.contentHash);
    await expectLater(approval, throwsStateError);
    await editing;
    expect(container.read(taskPlansProvider)['c']!.approved, isFalse);
  });
  test(
    'backup keeps plan text but strips bindings, evidence authority and approvals',
    () async {
      final plan = await propose();
      await plans.approve('c', 1, plan.contentHash);
      final raw = container
          .read(sharedPrefsProvider)
          .getString(TaskPlans.storageKey);
      final exported = TaskDataBackup.exportValues(
        {TaskDataBackup.planKey: raw},
        {'c'},
      );
      final restored = TaskDataBackup.restoreValues(
        {},
        exported,
        (id) => 'copy-$id',
      );
      final copy = TaskDataBackup.plans(
        restored[TaskDataBackup.planKey],
      )['copy-c']!;
      expect(copy.body, plan.body);
      expect(copy.approved, isFalse);
      expect(copy.target, isEmpty);
      expect(copy.status, TaskPlanStatus.cancelled);
      expect(copy.taskId, 'copy-root-task');
    },
  );
}
