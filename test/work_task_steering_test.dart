import 'package:expert_chat/state/work_task_steering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'steering persists receipt, separates roots, prepares once and cancels queued on stop',
    () async {
      final disk = <String, String>{};
      TaskSteeringStore open() => TaskSteeringStore(
        read: (key) => disk[key],
        write: (key, value) async {
          disk[key] = value;
          return true;
        },
      );
      final store = open();
      final one = await store.enqueue('c', 'rootA', 'user original supplement');
      await store.enqueue('other', 'rootA', 'private other conversation');
      expect((await store.prepare('c', 'rootB', 1)), isEmpty);
      expect((await store.prepare('c', 'rootA', 2)).single['id'], one['id']);
      expect(await store.prepare('c', 'rootA', 3), isEmpty);
      expect(
        open().instructions('c', 'rootA'),
        contains('user original supplement'),
      );
      expect(open().instructions('c', 'rootB'), isEmpty);
      expect(
        open().instructions('c', 'rootA'),
        isNot(contains('private other')),
      );
      await store.enqueue('c', 'rootA', 'pending change');
      await store.cancelPending('c', 'rootA');
      expect(store.snapshot('c').last['status'], 'cancelled');
      expect(
        store.instructions('c', 'rootA'),
        isNot(contains('pending change')),
      );
    },
  );
  test(
    'failed storage does not falsely acknowledge steering from mutated prefs cache',
    () async {
      final disk = <String, String>{};
      final store = TaskSteeringStore(
        read: (key) => disk[key],
        write: (key, value) async {
          disk[key] = value;
          return false;
        },
      );
      await expectLater(store.enqueue('c', 't', 'not saved'), throwsStateError);
      expect(store.snapshot('c'), isEmpty);
    },
  );
}
